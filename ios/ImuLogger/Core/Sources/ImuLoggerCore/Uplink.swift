import Foundation
import Network

/// Streams a session to the Mac receiver over TCP (ADR 0004): handshake,
/// acknowledgements, reconnect with backoff, and resend after interruptions.
///
/// All state is confined to a private serial queue. Callers may use it from
/// any thread; status updates arrive on that queue.
public final class Uplink: @unchecked Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case connecting(attempt: Int)
        case handshaking
        case streaming
        case waitingToRetry(attempt: Int, delay: Double)
        case rejected(String)
        case finished
    }

    public struct Status: Equatable, Sendable {
        public var state: State
        public var acknowledged: Seq?
        public var unacknowledgedSamples: UInt64
        public var queuedMessages: Int
        public var reconnects: Int
        public var lastError: String?
    }

    private let queue = DispatchQueue(label: "cwb.uplink")
    private let endpoint: NWEndpoint
    private let hello: Hello
    private let logURL: URL?
    private let onStatus: @Sendable (Status) -> Void

    private var connection: NWConnection?
    private var generation = 0
    private var decoder = FrameDecoder()
    private var tracker: DeliveryTracker
    private var queued: [Message] = []
    private let maxQueued = 1000
    private var state = State.idle
    private var attempt = 0
    private var reconnects = 0
    private var everStreamed = false
    private var lastError: String?
    private var pendingBye: Bye?

    /// - Parameters:
    ///   - logURL: the session log, reread when more is unacknowledged than fits in memory.
    ///   - maxPendingBatches: unacknowledged batches kept in memory for resending.
    public init(
        endpoint: NWEndpoint, hello: Hello, logURL: URL?, maxPendingBatches: Int = 600,
        onStatus: @escaping @Sendable (Status) -> Void
    ) {
        self.endpoint = endpoint
        self.hello = hello
        self.logURL = logURL
        self.tracker = DeliveryTracker(maxPendingBatches: maxPendingBatches)
        self.onStatus = onStatus
    }

    public func start() {
        queue.async { self.connect() }
    }

    /// Sends a sample batch that has already been written to the session log.
    public func send(batch: SampleBatch) {
        queue.async {
            self.tracker.record(batch)
            if self.state == .streaming { self.transmit(.sampleBatch(batch)) }
            self.publish()
        }
    }

    /// Sends a marker or event. Queued while disconnected (oldest dropped when
    /// full); not acknowledged, so the session log is the backstop.
    public func send(_ message: Message) {
        queue.async {
            if self.state == .streaming {
                self.transmit(message)
            } else {
                self.queued.append(message)
                if self.queued.count > self.maxQueued { self.queued.removeFirst() }
            }
            self.publish()
        }
    }

    /// Ends the session: waits up to `timeout` for outstanding batches to be
    /// acknowledged, sends `bye`, and closes.
    public func finish(with bye: Bye, timeout: TimeInterval = 5) {
        queue.async {
            self.pendingBye = bye
            self.sendByeIfReady()
            self.queue.asyncAfter(deadline: .now() + timeout) {
                guard self.pendingBye != nil else { return }
                if self.state == .streaming {
                    self.transmitBye()
                } else {
                    self.close(final: .finished)
                }
            }
        }
    }

    /// Stops immediately without sending `bye`.
    public func cancel() {
        queue.async { self.close(final: .finished) }
    }

    // MARK: - Connection lifecycle (on queue)

    private func connect() {
        guard state == .idle else { return }
        connectNow()
    }

    private func connectNow() {
        generation += 1
        let current = generation
        attempt += 1
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        let connection = NWConnection(to: endpoint, using: NWParameters(tls: nil, tcp: tcp))
        self.connection = connection
        decoder = FrameDecoder()
        state = .connecting(attempt: attempt)
        connection.stateUpdateHandler = { [weak self] newState in
            self?.handle(newState, generation: current)
        }
        connection.start(queue: queue)
        publish()
    }

    private func handle(_ newState: NWConnection.State, generation current: Int) {
        guard current == generation else { return }
        switch newState {
        case .ready:
            state = .handshaking
            transmit(.hello(hello))
            receive(generation: current)
            publish()
        case .waiting(let error), .failed(let error):
            retry(after: error.debugDescription)
        default:
            break
        }
    }

    private func receive(generation current: Int) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, error in
            guard let self, current == self.generation else { return }
            if let data, !data.isEmpty {
                self.decoder.push(data)
                do {
                    while let message = try self.decoder.nextMessage() {
                        self.handle(message)
                        guard current == self.generation else { return }
                    }
                } catch {
                    return self.retry(after: "bad frame from receiver: \(error)")
                }
            }
            if let error {
                self.retry(after: error.debugDescription)
            } else if isComplete {
                self.retry(after: "receiver closed the connection")
            } else {
                self.receive(generation: current)
            }
        }
    }

    private func handle(_ message: Message) {
        switch message {
        case .helloAck(let ack):
            guard ack.sessionId == hello.sessionId else {
                return close(final: .rejected("hello_ack for a different session"))
            }
            guard ack.accepted else {
                return close(final: .rejected(ack.reason ?? "receiver rejected the session"))
            }
            if everStreamed { reconnects += 1 }
            everStreamed = true
            attempt = 0
            lastError = nil
            state = .streaming
            resend(tracker.reconnected(macHighest: ack.highestContiguousSeq))
            let backlog = queued
            queued.removeAll()
            backlog.forEach(transmit)
            sendByeIfReady()
        case .batchAck(let ack):
            tracker.acknowledge(ack.highestContiguousSeq)
            sendByeIfReady()
        case .error(let error):
            switch error.code {
            case .unsupportedVersion, .deviceMismatch, .unknownSession:
                close(final: .rejected("\(error.code.rawValue): \(error.message)"))
            case .invalidMessage, .internal:
                retry(after: "receiver error: \(error.message)")
            }
        default:
            break  // clock_pong is handled from plan Prompt 4.
        }
        publish()
    }

    private func resend(_ plan: DeliveryTracker.Resend) {
        switch plan {
        case .batches(let batches):
            batches.forEach { transmit(.sampleBatch($0)) }
        case .fromLog(let after):
            guard let logURL else {
                lastError = "cannot resend: no session log"
                return
            }
            do {
                try SessionLog.batches(in: logURL, after: after).forEach {
                    transmit(.sampleBatch($0))
                }
            } catch {
                lastError = "cannot reread session log: \(error)"
            }
        }
    }

    private func sendByeIfReady() {
        guard pendingBye != nil, state == .streaming, tracker.unacknowledgedSamples == 0 else {
            return
        }
        transmitBye()
    }

    private func transmitBye() {
        guard let bye = pendingBye, let connection else { return }
        pendingBye = nil
        if let frame = try? Framing.encode(.bye(bye)) {
            connection.send(
                content: frame,
                completion: .contentProcessed { [weak self] _ in
                    self?.close(final: .finished)
                })
        } else {
            close(final: .finished)
        }
    }

    private func transmit(_ message: Message) {
        guard let connection, let frame = try? Framing.encode(message) else { return }
        let current = generation
        connection.send(
            content: frame,
            completion: .contentProcessed { [weak self] error in
                guard let self, let error, current == self.generation else { return }
                self.retry(after: error.debugDescription)
            })
    }

    private func retry(after reason: String) {
        switch state {
        case .rejected, .finished, .waitingToRetry: return
        default: break
        }
        lastError = reason
        connection?.cancel()
        connection = nil
        generation += 1
        let current = generation
        let delay = min(5, 0.25 * pow(2, Double(max(attempt - 1, 0))))
        state = .waitingToRetry(attempt: attempt, delay: delay)
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, current == self.generation else { return }
            self.connectNow()
        }
        publish()
    }

    private func close(final: State) {
        if case .finished = state { return }
        generation += 1
        connection?.cancel()
        connection = nil
        state = final
        publish()
    }

    private func publish() {
        onStatus(
            Status(
                state: state, acknowledged: tracker.acknowledged,
                unacknowledgedSamples: tracker.unacknowledgedSamples,
                queuedMessages: queued.count, reconnects: reconnects, lastError: lastError))
    }
}
