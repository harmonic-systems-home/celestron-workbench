import Foundation
import Network
import Synchronization

@testable import ImuLoggerCore

/// A minimal stand-in for the Mac receiver, listening on loopback. Stores
/// sequence numbers, acknowledges the highest contiguous one, and can drop the
/// connection or forget data to simulate interruptions.
final class FakeReceiver: @unchecked Sendable {
    struct State {
        var stored: Set<Seq> = []
        var duplicates = 0
        var hellos = 0
        var byes = 0
        var others: [Message] = []
        var acceptSessions = true
        var connection: NWConnection?

        var highestContiguous: Seq? {
            var next: Seq = 0
            while stored.contains(next) { next += 1 }
            return next == 0 ? nil : next - 1
        }
    }

    let state = Mutex(State())
    private let ready = Mutex(false)
    private let listener: NWListener
    private let queue = DispatchQueue(label: "fake-receiver")

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.stateUpdateHandler = { [weak self] newState in
            if case .ready = newState { self?.ready.withLock { $0 = true } }
        }
        listener.start(queue: queue)
    }

    var endpoint: NWEndpoint {
        get async {
            // The port reads as 0 until the listener is ready.
            _ = await eventually {
                self.ready.withLock { $0 } && (self.listener.port?.rawValue ?? 0) != 0
            }
            return .hostPort(host: "127.0.0.1", port: listener.port!)
        }
    }

    func dropConnection() {
        state.withLock { $0.connection?.cancel() }
    }

    /// Simulates a receiver that lost everything after `seq`.
    func forget(after seq: Seq) {
        state.withLock { $0.stored = $0.stored.filter { $0 <= seq } }
    }

    func stop() {
        listener.cancel()
        dropConnection()
    }

    private func accept(_ connection: NWConnection) {
        state.withLock {
            $0.connection?.cancel()
            $0.connection = connection
        }
        connection.start(queue: queue)
        var decoder = FrameDecoder()
        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
                data, _, isComplete, error in
                if let data { decoder.push(data) }
                while let message = try? decoder.nextMessage() {
                    if let reply = self.handle(message) {
                        connection.send(
                            content: try! Framing.encode(reply), completion: .idempotent)
                    }
                }
                if error == nil && !isComplete { receive() } else { connection.cancel() }
            }
        }
        receive()
    }

    private func handle(_ message: Message) -> Message? {
        state.withLock { state in
            switch message {
            case .hello(let hello):
                state.hellos += 1
                return .helloAck(
                    HelloAck(
                        protocolVersion: protocolVersion, sessionId: hello.sessionId,
                        accepted: state.acceptSessions,
                        highestContiguousSeq: state.highestContiguous,
                        reason: state.acceptSessions ? nil : "test rejection"))
            case .sampleBatch(let batch):
                for sample in batch.samples where !state.stored.insert(sample.seq).inserted {
                    state.duplicates += 1
                }
                guard let highest = state.highestContiguous else { return nil }
                return .batchAck(
                    BatchAck(
                        protocolVersion: protocolVersion, sessionId: batch.sessionId,
                        deviceId: batch.deviceId, highestContiguousSeq: highest))
            case .bye:
                state.byes += 1
                return nil
            default:
                state.others.append(message)
                return nil
            }
        }
    }
}
