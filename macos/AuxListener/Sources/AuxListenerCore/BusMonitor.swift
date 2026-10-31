/// A packet with its meaning: who to whom, what, and whether it answers an
/// earlier request.
public struct DecodedPacket: Equatable, Sendable {
    public let packet: AuxPacket
    public let at: UInt64
    /// Answers a request seen earlier (same message, the other way).
    public let isReply: Bool
    /// From the request to this reply.
    public let latencyMs: Double?
    /// A routine read (positions, goto-finished), hidden from the feed by default.
    public let isPolling: Bool
    /// "Hand control → Azimuth  MOVE_POS rate 5".
    public let text: String
}

public struct Anomaly: Equatable, Sendable {
    public let kind: AnomalyKind
    public let at: UInt64
    public let bytes: [UInt8]
    public let detail: String
}

public enum BusEvent: Equatable, Sendable {
    case packet(DecodedPacket)
    case anomaly(Anomaly)
}

/// Pairs requests with replies, flags requests nobody answers, and turns
/// packets into readable lines. Times are monotonic nanoseconds.
public struct BusMonitor: Sendable {
    public var replyTimeoutNs: UInt64

    private struct Pending: Sendable {
        let source: UInt8
        let destination: UInt8
        let id: UInt8
        let at: UInt64
        let raw: [UInt8]
    }

    private var pending: [Pending] = []

    public init(replyTimeoutNs: UInt64 = 500_000_000) {
        self.replyTimeoutNs = replyTimeoutNs
    }

    public mutating func process(_ event: FramerEvent) -> [BusEvent] {
        switch event {
        case .anomaly(let kind, let bytes, let at):
            let anomaly = Anomaly(
                kind: kind, at: at, bytes: bytes,
                detail: "\(kind.label): \(bytes.count) byte(s) \(hexBytes(bytes.prefix(16)))")
            return expire(at: at) + [.anomaly(anomaly)]
        case .packet(let packet, let at):
            var out = expire(at: at)
            if let i = pending.firstIndex(where: {
                $0.source == packet.destination && $0.destination == packet.source
                    && $0.id == packet.id
            }) {
                let request = pending.remove(at: i)
                let latency = Double(at - request.at) / 1e6
                out.append(.packet(decode(packet, at: at, reply: true, latencyMs: latency)))
            } else {
                // Messages to "any" are announcements: nobody replies.
                if packet.destination != 0x00 {
                    pending.append(
                        Pending(
                            source: packet.source, destination: packet.destination,
                            id: packet.id, at: at, raw: packet.raw))
                }
                out.append(.packet(decode(packet, at: at, reply: false, latencyMs: nil)))
            }
            return out
        }
    }

    /// Requests older than the timeout become "no reply" anomalies.
    public mutating func expire(at now: UInt64) -> [BusEvent] {
        let timeout = replyTimeoutNs
        let late = { (p: Pending) in now >= p.at && now - p.at > timeout }
        let expired = pending.filter(late)
        pending.removeAll(where: late)
        return expired.map { p in
            let what = describe(source: p.source, destination: p.destination, id: p.id)
            return .anomaly(
                Anomaly(kind: .noReply, at: p.at, bytes: p.raw, detail: "No reply: \(what)"))
        }
    }

    func decode(_ p: AuxPacket, at: UInt64, reply: Bool, latencyMs: Double?) -> DecodedPacket {
        let motor = AuxDevice.isMotor(p.source) || AuxDevice.isMotor(p.destination)
        var text = describe(source: p.source, destination: p.destination, id: p.id)
        if let value = motor ? value(p, reply: reply) : nil {
            text += reply ? " = \(value)" : " \(value)"
        } else if !p.data.isEmpty {
            text += " [\(hexBytes(p.data))]"
        } else if reply {
            text += " ok"
        }
        if let latencyMs {
            text += " (\(Int(latencyMs.rounded())) ms)"
        }
        return DecodedPacket(
            packet: p, at: at, isReply: reply, latencyMs: latencyMs,
            isPolling: motor && MotorMessage.isPolling(p.id), text: text)
    }

    private func describe(source: UInt8, destination: UInt8, id: UInt8) -> String {
        let motor = AuxDevice.isMotor(source) || AuxDevice.isMotor(destination)
        let message = (motor ? MotorMessage.name(id) : nil) ?? "msg \(hex(id))"
        return "\(AuxDevice.name(source)) → \(AuxDevice.name(destination))  \(message)"
    }

    /// The data of motor-controller messages we know, in words.
    private func value(_ p: AuxPacket, reply: Bool) -> String? {
        let d = p.data[...]
        switch (p.id, reply) {
        case (0x01, true), (0x02, false), (0x04, false), (0x17, false):
            return degrees(d).map { String(format: "%.5f°", $0) }
        case (0x24, false), (0x25, false):
            guard let rate = d.first else { return nil }
            return rate == 0 ? "stop" : "rate \(rate)"
        case (0x13, true), (0x18, true):
            guard let flag = d.first else { return nil }
            return flag == 0xFF ? "yes" : "no"
        case (0x10, false), (0x11, false), (0x40, true), (0x41, true):
            return d.first.map { "\($0)" }
        case (0xfc, true), (0xfd, false):
            guard let sense = d.first else { return nil }
            return sense == 0 ? "positive" : sense == 1 ? "negative" : nil
        case (0xfe, true):
            guard d.count >= 2 else { return nil }
            return "\(d[d.startIndex]).\(d[d.startIndex + 1])"
        default:
            return nil
        }
    }
}
