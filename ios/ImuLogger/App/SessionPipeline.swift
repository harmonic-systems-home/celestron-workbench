import Foundation
import ImuLoggerCore

/// Drains the acquisition buffer on its own queue: builds batches, writes the
/// session log, sends to the Mac, and measures rates, drops and continuity.
/// The log is always written before anything is sent (ADR 0006).
final class SessionPipeline: @unchecked Sendable {
    struct Snapshot: Sendable {
        var samples: Seq = 0
        var dropped: UInt64 = 0
        var bufferHighWater = 0
        var rates: [SensorStream: RateMeter.Summary] = [:]
        var rotationFromStartRad: Double?
        var discontinuities = 0
        var uplink: Uplink.Status?
        var logError: String?
    }

    static let drainInterval: TimeInterval = 0.1
    static let maxBatchSamples = 250
    static let rateReportInterval: TimeInterval = 10

    let sessionId: String
    let deviceId: String
    let buffer: AcquisitionBuffer
    let log: SessionLog
    private let queue = DispatchQueue(label: "cwb.pipeline", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    // Confined to `queue`.
    private var windowMeter = RateMeter()
    private var sessionMeter = RateMeter()
    private var continuity = AttitudeContinuityMonitor()
    private var firstAttitude: Quaternion?
    private var lastAttitude: Quaternion?
    private var reportedDrops: [SensorStream: UInt64] = [:]
    private var lastRateReport = Date()
    private var lastPressureReport = Date.distantPast
    private var discontinuities = 0
    private var logError: String?
    private var uplinkStatus: Uplink.Status?

    init(
        sessionId: String, deviceId: String, bufferCapacity: Int, log: SessionLog,
        uplink: @escaping (SessionPipeline) -> Uplink?
    ) {
        self.sessionId = sessionId
        self.deviceId = deviceId
        self.buffer = AcquisitionBuffer(capacity: bufferCapacity)
        self.log = log
        self.uplinkFactory = uplink
    }

    /// Builds the uplink once the hello is logged; it needs `self` for status updates.
    private var uplinkFactory: ((SessionPipeline) -> Uplink?)?
    private var activeUplink: Uplink?

    func start(hello: Hello) {
        queue.sync {
            write(.hello(hello))
            activeUplink = uplinkFactory?(self)
            uplinkFactory = nil
            activeUplink?.start()
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.drainInterval, repeating: Self.drainInterval)
        timer.setEventHandler { [weak self] in self?.drain() }
        timer.resume()
        self.timer = timer
    }

    /// Sends a marker or event, logging it first.
    func emit(_ message: Message) {
        queue.async { self.emitNow(message) }
    }

    func event(
        _ kind: SessionEvent.Kind, _ severity: SessionEvent.Severity = .info,
        detail: [String: JSONValue] = [:]
    ) {
        let message = Message.event(
            SessionEvent(
                protocolVersion: protocolVersion, sessionId: sessionId, deviceId: deviceId,
                tNs: PhoneClock.nowNs(), kind: kind, severity: severity, detail: detail))
        emit(message)
    }

    func uplinkStatusChanged(_ status: Uplink.Status) {
        queue.async { self.uplinkStatus = status }
    }

    /// Stops draining after a final drain, then sends `bye` and closes the log.
    func finish(reason: Bye.Reason) {
        queue.sync {
            timer?.cancel()
            timer = nil
            drain()
            reportRates()
            let counters = buffer.counters
            let bye = Bye(
                protocolVersion: protocolVersion, sessionId: sessionId, deviceId: deviceId,
                lastSeq: counters.nextSeq == 0 ? nil : counters.nextSeq - 1, reason: reason)
            write(.bye(bye))
            activeUplink?.finish(with: bye)
            do { try log.close() } catch { logError = "closing log: \(error)" }
        }
    }

    func snapshot() -> Snapshot {
        queue.sync {
            let counters = buffer.counters
            return Snapshot(
                samples: counters.nextSeq, dropped: counters.dropped,
                bufferHighWater: counters.highWater,
                rates: Dictionary(
                    uniqueKeysWithValues: sessionMeter.activeStreams.map {
                        ($0, sessionMeter.summary(for: $0))
                    }),
                rotationFromStartRad: firstAttitude.flatMap { first in
                    lastAttitude.flatMap { first.angle(to: $0) }
                },
                discontinuities: discontinuities, uplink: uplinkStatus, logError: logError)
        }
    }

    // MARK: - On queue

    private func drain() {
        let pressure = buffer.count
        let samples = buffer.drain()
        if pressure * 4 >= buffer.capacity * 3,
            Date().timeIntervalSince(lastPressureReport) > 10
        {
            lastPressureReport = Date()
            emitNow(
                eventMessage(
                    .bufferPressure, .warning,
                    [
                        "buffered": .number(Double(pressure)),
                        "capacity": .number(Double(buffer.capacity)),
                    ]
                ))
        }
        for sample in samples {
            windowMeter.record(sample)
            sessionMeter.record(sample)
            if case .deviceMotion(let motion) = sample {
                if firstAttitude == nil { firstAttitude = motion.attitude }
                lastAttitude = motion.attitude
                if let jump = continuity.check(motion) {
                    discontinuities += 1
                    emitNow(
                        eventMessage(
                            .attitudeDiscontinuity, .warning,
                            [
                                "seq": .number(Double(jump.seq)),
                                "jump_rad": .number(jump.jumpRad),
                                "explained_rad": .number(jump.explainedRad),
                                "gap_ns": .number(Double(jump.gapNs)),
                            ]))
                }
            }
        }
        for batch in makeBatches(
            samples, sessionId: sessionId, deviceId: deviceId, maxSamples: Self.maxBatchSamples)
        {
            write(.sampleBatch(batch))
            activeUplink?.send(batch: batch)
        }
        reportDrops()
        if Date().timeIntervalSince(lastRateReport) >= Self.rateReportInterval {
            reportRates()
        }
    }

    private func reportDrops() {
        let dropped = buffer.counters.droppedByStream
        for (stream, total) in dropped where total > reportedDrops[stream, default: 0] {
            let new = total - reportedDrops[stream, default: 0]
            reportedDrops[stream] = total
            emitNow(
                eventMessage(
                    .droppedSamples, .warning,
                    [
                        "stream": .string(stream.rawValue), "count": .number(Double(new)),
                        "total": .number(Double(total)),
                    ]))
        }
    }

    private func reportRates() {
        lastRateReport = Date()
        var detail: [String: JSONValue] = [:]
        for stream in windowMeter.activeStreams {
            let s = windowMeter.summary(for: stream)
            var entry: [String: JSONValue] = ["count": .number(Double(s.count))]
            if let rate = s.rateHz { entry["rate_hz"] = .number(rate) }
            if let mean = s.meanIntervalNs { entry["mean_interval_ns"] = .number(mean) }
            if let min = s.minIntervalNs { entry["min_interval_ns"] = .number(Double(min)) }
            if let max = s.maxIntervalNs { entry["max_interval_ns"] = .number(Double(max)) }
            detail[stream.rawValue] = .object(entry)
        }
        windowMeter.resetWindow()
        guard !detail.isEmpty else { return }
        emitNow(eventMessage(.effectiveRate, .info, detail))
    }

    private func eventMessage(
        _ kind: SessionEvent.Kind, _ severity: SessionEvent.Severity, _ detail: [String: JSONValue]
    ) -> Message {
        .event(
            SessionEvent(
                protocolVersion: protocolVersion, sessionId: sessionId, deviceId: deviceId,
                tNs: PhoneClock.nowNs(), kind: kind, severity: severity, detail: detail))
    }

    private func emitNow(_ message: Message) {
        write(message)
        activeUplink?.send(message)
    }

    /// Logs a message. A failed write is surfaced in the UI, but sending still
    /// goes ahead: the Mac copy is better than none.
    private func write(_ message: Message) {
        do {
            try log.append(message)
        } catch {
            logError = "writing log: \(error)"
        }
    }
}
