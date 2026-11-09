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
    /// A packet with another whole packet inside it: `outer` stopped partway
    /// (seen after its first two or three bytes) and `inner` was sent in the
    /// gap. `raw` is every byte as it arrived.
    case split(outer: AuxPacket, inner: AuxPacket, raw: [UInt8], at: UInt64, innerAt: UInt64)
}

/// Splits the bus's byte stream into packets. Reads arrive in chunks, each
/// with the time it was read (monotonic nanoseconds). A frame that sees no
/// byte for `gapNs` is reported as cut short; bytes that can't start a frame
/// are gathered and reported as stray.
public struct Framer: Sendable {
    /// At 19,200 baud a byte takes about 0.5 ms, but USB delivers bytes in
    /// batches about 16 ms apart, and a whole reply was seen split across a
    /// 33 ms gap. A pause this long inside a frame means it was cut off.
    public var gapNs: UInt64

    private var frame: [UInt8] = []
    private var frameStart: UInt64 = 0
    private var stray: [UInt8] = []
    private var strayStart: UInt64 = 0
    private var lastByte: UInt64 = 0
    /// Where a second frame seems to start inside the current one, after the
    /// current one's checksum failed; nil while framing normally.
    private var weave: (index: Int, at: UInt64)?

    public init(gapNs: UInt64 = 50_000_000) {
        self.gapNs = gapNs
    }

    public mutating func feed(_ bytes: [UInt8], at t: UInt64) -> [FramerEvent] {
        var out = flush(at: t)
        out += consume(bytes[...], at: t)
        if !bytes.isEmpty { lastByte = t }
        return out
    }

    private mutating func consume(_ bytes: ArraySlice<UInt8>, at t: UInt64) -> [FramerEvent] {
        var out: [FramerEvent] = []
        var rest = bytes
        while let byte = rest.popFirst() {
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
            let outerCount = Int(frame[1]) + 3
            if let w = weave {
                // Waiting for the inner frame's length, then for both whole.
                guard frame.count > w.index + 1 else { continue }
                let innerLength = Int(frame[w.index + 1])
                guard innerLength >= 3, innerLength <= Aux.maxLength else {
                    out += unweave(at: t, then: &rest)
                    continue
                }
                guard frame.count == outerCount + innerLength + 3 else { continue }
                let innerEnd = w.index + innerLength + 3
                if let inner = AuxPacket(raw: Array(frame[w.index..<innerEnd])),
                    let outer = AuxPacket(raw: Array(frame[..<w.index] + frame[innerEnd...]))
                {
                    out.append(
                        .split(
                            outer: outer, inner: inner, raw: frame, at: frameStart, innerAt: w.at))
                    frame = []
                    weave = nil
                } else {
                    out += unweave(at: t, then: &rest)
                }
                continue
            }
            if frame.count == outerCount {
                if let packet = AuxPacket(raw: frame) {
                    out.append(.packet(packet, at: frameStart))
                    frame = []
                } else if let i = frame.indices.dropFirst(2).first(where: {
                    frame[$0] == Aux.preamble
                }) {
                    // Perhaps another packet came in a pause in this one.
                    weave = (i, t)
                    if frame.count > i + 1 {
                        let innerLength = Int(frame[i + 1])
                        if innerLength < 3 || innerLength > Aux.maxLength {
                            out += unweave(at: t, then: &rest)
                        }
                    }
                } else {
                    out.append(.anomaly(.badChecksum, bytes: frame, at: frameStart))
                    frame = []
                }
            }
        }
        return out
    }

    /// The bytes didn't make two packets after all: the first frame is a bad
    /// checksum, and what was gathered after it goes back to normal framing.
    private mutating func unweave(at t: UInt64, then rest: inout ArraySlice<UInt8>)
        -> [FramerEvent]
    {
        let outerCount = Int(frame[1]) + 3
        let bad = Array(frame[..<outerCount])
        let extra = frame[outerCount...]
        frame = []
        weave = nil
        rest = extra + rest
        return [.anomaly(.badChecksum, bytes: bad, at: frameStart)]
    }

    /// Reports a frame left unfinished, and stray bytes, once the line has
    /// been quiet for `gapNs`. Call it on a timer as well as on reads.
    public mutating func flush(at t: UInt64) -> [FramerEvent] {
        guard t >= lastByte, t - lastByte > gapNs else { return [] }
        var out = takeStray()
        if weave != nil {
            var rest: ArraySlice<UInt8> = []
            out += unweave(at: t, then: &rest)
            out += consume(rest, at: t)
            out += takeStray()
        }
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
