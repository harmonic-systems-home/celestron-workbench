/// What can go wrong on the wire (ADR 0018).
public enum AnomalyKind: String, CaseIterable, Sendable {
    /// A whole frame whose checksum doesn't match: often two senders at once.
    case badChecksum = "bad_checksum"
    /// A length byte too small or too large to be a packet.
    case badLength = "bad_length"
    /// A frame that stopped partway: the line went quiet before the end.
    case truncated
    /// Bytes outside any frame.
    case noise
    /// A request that nobody answered in time.
    case noReply = "no_reply"

    public var label: String {
        switch self {
        case .badChecksum: "Bad checksum"
        case .badLength: "Bad length"
        case .truncated: "Cut short"
        case .noise: "Stray bytes"
        case .noReply: "No reply"
        }
    }
}

public enum FramerEvent: Equatable, Sendable {
    /// A packet, timed by the read that brought its first byte.
    case packet(AuxPacket, at: UInt64)
    case anomaly(AnomalyKind, bytes: [UInt8], at: UInt64)
}

/// Splits the bus's byte stream into packets. Reads arrive in chunks, each
/// with the time it was read (monotonic nanoseconds). A frame that sees no
/// byte for `gapNs` is reported as cut short; bytes that can't start a frame
/// are gathered and reported as stray.
public struct Framer: Sendable {
    /// At 19,200 baud a byte takes about 0.5 ms; a pause this long inside a
    /// frame means it was cut off.
    public var gapNs: UInt64

    private var frame: [UInt8] = []
    private var frameStart: UInt64 = 0
    private var stray: [UInt8] = []
    private var strayStart: UInt64 = 0
    private var lastByte: UInt64 = 0

    public init(gapNs: UInt64 = 20_000_000) {
        self.gapNs = gapNs
    }

    public mutating func feed(_ bytes: [UInt8], at t: UInt64) -> [FramerEvent] {
        var out = flush(at: t)
        for byte in bytes {
            if frame.isEmpty {
                if byte == Aux.preamble {
                    out += takeStray()
                    frame = [byte]
                    frameStart = t
                } else {
                    if stray.isEmpty { strayStart = t }
                    stray.append(byte)
                }
                continue
            }
            frame.append(byte)
            if frame.count == 2 {
                let length = Int(byte)
                if length < 3 || length > Aux.maxLength {
                    out.append(.anomaly(.badLength, bytes: frame, at: frameStart))
                    frame = []
                }
                continue
            }
            if frame.count == Int(frame[1]) + 3 {
                if let packet = AuxPacket(raw: frame) {
                    out.append(.packet(packet, at: frameStart))
                } else {
                    out.append(.anomaly(.badChecksum, bytes: frame, at: frameStart))
                }
                frame = []
            }
        }
        if !bytes.isEmpty { lastByte = t }
        return out
    }

    /// Reports a frame left unfinished, and stray bytes, once the line has
    /// been quiet for `gapNs`. Call it on a timer as well as on reads.
    public mutating func flush(at t: UInt64) -> [FramerEvent] {
        guard t >= lastByte, t - lastByte > gapNs else { return [] }
        var out = takeStray()
        if !frame.isEmpty {
            out.append(.anomaly(.truncated, bytes: frame, at: frameStart))
            frame = []
        }
        return out
    }

    private mutating func takeStray() -> [FramerEvent] {
        guard !stray.isEmpty else { return [] }
        defer { stray = [] }
        return [.anomaly(.noise, bytes: stray, at: strayStart)]
    }
}
