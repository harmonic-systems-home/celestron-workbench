/// A packet with its meaning: who to whom, what, and whether it answers an
/// earlier request.
public struct DecodedPacket: Equatable, Sendable {
    public let packet: AuxPacket
    public let at: UInt64
    /// Answers a request (same message, the other way), or is a device's
    /// answer to a controller after its request timed out.
    public let isReply: Bool
    /// From the request to this reply; nil if the reply came too late to pair.
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

/// A frame that breaks the rules in a way we've seen before and understand
/// well enough not to call a fault: logged and shown, not counted or sounded.
public struct KnownFrame: Equatable, Sendable {
    public let at: UInt64
    public let bytes: [UInt8]
    /// Stable name for the log, such as `probe_checksum_00`.
    public let kind: String
    public let text: String
}

public enum BusEvent: Equatable, Sendable {
    case packet(DecodedPacket)
    case anomaly(Anomaly)
    case known(KnownFrame)
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
    /// Devices that have sent something this session.
    private var heard: Set<UInt8> = []
    /// Recent requests, raw, for recognising a repeat with a zeroed checksum.
    private var recent: [(raw: [UInt8], at: UInt64)] = []
    /// How far back a zeroed-checksum frame may repeat its request.
    private let repeatWindowNs: UInt64 = 2_000_000_000

    public init(replyTimeoutNs: UInt64 = 500_000_000) {
        self.replyTimeoutNs = replyTimeoutNs
    }

    public mutating func process(_ event: FramerEvent) -> [BusEvent] {
        switch event {
        case .split(let outer, let inner, let raw, let at, let innerAt):
            // Seen with SkySafari over Wi-Fi: its request stops after the
            // first two or three bytes and a reply is sent in the gap.
            let note = KnownFrame(
                at: at, bytes: raw, kind: "split_packet",
                text:
                    "\(describe(source: outer.source, destination: outer.destination, id: outer.id))"
                    + " split by \(describe(source: inner.source, destination: inner.destination, id: inner.id))"
            )
            return [.known(note)] + process(.packet(inner, at: innerAt))
                + process(.packet(outer, at: at))
        case .anomaly(let kind, let bytes, let at):
            if kind == .badChecksum, let known = probeRepeat(bytes, at: at) {
                return expire(at: at) + [.known(known)]
            }
            let anomaly = Anomaly(
                kind: kind, at: at, bytes: bytes,
                detail: "\(kind.label): \(bytes.count) byte(s) \(hexBytes(bytes.prefix(16)))")
            return expire(at: at) + [.anomaly(anomaly)]
        case .packet(let packet, let at):
            heard.insert(packet.source)
            var out = expire(at: at)
            if let i = pending.firstIndex(where: {
                $0.source == packet.destination && $0.destination == packet.source
                    && $0.id == packet.id
            }) {
                let request = pending.remove(at: i)
                let latency = Double(at - request.at) / 1e6
                out.append(.packet(decode(packet, at: at, reply: true, latencyMs: latency)))
            } else if !AuxDevice.isController(packet.source),
                AuxDevice.isController(packet.destination)
            {
                // A late answer, not a new request: the camera can take over a
                // second while it starts up.
                out.append(.packet(decode(packet, at: at, reply: true, latencyMs: nil)))
            } else {
                // Messages to "any" are announcements: nobody replies.
                if packet.destination != 0x00 {
                    recent.removeAll { at < $0.at || at - $0.at > repeatWindowNs }
                    recent.append((packet.raw, at))
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

    /// Seen at every startup on the mount (ADR 0018): about 0.5 s after the
    /// hand controller probes an accessory that doesn't answer, the same frame
    /// again with `00` where the checksum belongs. Recognised only when every
    /// byte but the last matches a recent request from a controller to an
    /// accessory not heard from; anything else stays a bad checksum.
    private func probeRepeat(_ bytes: [UInt8], at: UInt64) -> KnownFrame? {
        guard bytes.count >= 6, bytes.last == 0x00 else { return nil }
        let source = bytes[2]
        let destination = bytes[3]
        guard AuxDevice.isController(source), !AuxDevice.isMotor(destination),
            !heard.contains(destination),
            recent.contains(where: {
                at >= $0.at && at - $0.at <= repeatWindowNs
                    && $0.raw.dropLast() == bytes.dropLast()
            })
        else { return nil }
        let what = describe(source: source, destination: destination, id: bytes[4])
        return KnownFrame(
            at: at, bytes: bytes, kind: "probe_checksum_00",
            text: "\(what) repeated, checksum 00 (unanswered probe)")
    }

    /// Requests older than the timeout become "no reply" anomalies, except
    /// to an accessory not heard from yet: the hand controller also asks for
    /// devices that aren't fitted, or haven't finished starting up. A motor
    /// always has to answer.
    public mutating func expire(at now: UInt64) -> [BusEvent] {
        let timeout = replyTimeoutNs
        let late = { (p: Pending) in now >= p.at && now - p.at > timeout }
        let expired = pending.filter(late)
        pending.removeAll(where: late)
        let faults = expired.filter {
            AuxDevice.isMotor($0.destination) || heard.contains($0.destination)
        }
        return faults.map { p in
            let what = describe(source: p.source, destination: p.destination, id: p.id)
            return .anomaly(
                Anomaly(kind: .noReply, at: p.at, bytes: p.raw, detail: "No reply: \(what)"))
        }
    }

    func decode(_ p: AuxPacket, at: UInt64, reply: Bool, latencyMs: Double?) -> DecodedPacket {
        let motor = AuxDevice.isMotor(p.source) || AuxDevice.isMotor(p.destination)
        var text = describe(source: p.source, destination: p.destination, id: p.id)
        if let value = value(p, reply: reply) {
            text += reply ? " = \(value)" : " \(value)"
        } else if !p.data.isEmpty {
            text += " [\(hexBytes(p.data))]"
        } else if reply {
            text += " ok"
        }
        if let latencyMs {
            text += " (\(Int(latencyMs.rounded())) ms)"
        } else if reply {
            text += " (late)"
        }
        return DecodedPacket(
            packet: p, at: at, isReply: reply, latencyMs: latencyMs,
            isPolling: motor && MotorMessage.isPolling(p.id), text: text)
    }

    private func describe(source: UInt8, destination: UInt8, id: UInt8) -> String {
        let message: String?
        if AuxDevice.isMotor(source) || AuxDevice.isMotor(destination) {
            message = MotorMessage.name(id)
        } else if source == StarSenseMessage.address || destination == StarSenseMessage.address {
            message = StarSenseMessage.name(id)
        } else {
            message = nil
        }
        return
            "\(AuxDevice.name(source)) → \(AuxDevice.name(destination))  \(message ?? "msg \(hex(id))")"
    }

    /// The data of messages we know, in words.
    private func value(_ p: AuxPacket, reply: Bool) -> String? {
        if AuxDevice.isMotor(p.source) || AuxDevice.isMotor(p.destination) {
            return motorValue(p, reply: reply)
        }
        if p.source == StarSenseMessage.address || p.destination == StarSenseMessage.address {
            return starSenseValue(p, reply: reply)
        }
        return nil
    }

    private func starSenseValue(_ p: AuxPacket, reply: Bool) -> String? {
        let d = p.data[...]
        guard reply else { return nil }
        switch p.id {
        case 0x3f:
            guard let x = littleEndian32(d.prefix(4)), let y = littleEndian32(d.dropFirst(4)) else {
                return nil
            }
            return "x \(x), y \(y)"
        case 0x91:
            guard let status = d.first else { return nil }
            let stars = d.dropFirst().first.map { ", \($0) stars" } ?? ""
            return "status \(status)\(stars)"
        case 0xfe:
            guard d.count >= 2 else { return nil }
            return "\(d[d.startIndex]).\(d[d.startIndex + 1])"
        default:
            return nil
        }
    }

    private func motorValue(_ p: AuxPacket, reply: Bool) -> String? {
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
