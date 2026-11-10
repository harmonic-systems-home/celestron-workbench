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
    /// A frame that stopped partway and went on after a pause, with any
    /// garbled bytes that came with it: one event, not several.
    case paused

    public var label: String {
        switch self {
        case .badChecksum: "Bad checksum"
        case .badLength: "Bad length"
        case .truncated: "Cut short"
        case .noise: "Stray bytes"
        case .noReply: "No reply"
        case .paused: "Paused mid-packet"
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
    /// A `3C` bulk frame with a valid checksum: seen after the StarSense
    /// camera's capture data answer. `bytes` is the whole frame.
    case bulk(bytes: [UInt8], at: UInt64)
    /// A frame cut short, then more broken bytes soon after: `bytes` is all
    /// of them in order, from `at` to `resumedAt` (see `PauseJoiner`).
    case paused(bytes: [UInt8], at: UInt64, resumedAt: UInt64)
}

/// The `3C` bulk frame, from one capture on this mount (ADR 0018): `3C`, a
/// 4-byte big-endian data length, the data, and a checksum like a packet's
/// (two's complement of the sum from the first length byte on).
public enum Bulk {
    public static let preamble: UInt8 = 0x3C
    /// Longest data length accepted; longer is treated as stray bytes.
    public static let maxLength = 4096
    static let headerCount = 5
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
    private var bulk: [UInt8] = []
    private var bulkStart: UInt64 = 0

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
            if !bulk.isEmpty {
                bulk.append(byte)
                guard bulk.count >= Bulk.headerCount else { continue }
                let length = bulk[1..<Bulk.headerCount].reduce(0) { $0 << 8 | Int($1) }
                guard length <= Bulk.maxLength else {
                    // Not a bulk frame: the 3C is stray, the rest is framed again.
                    if stray.isEmpty { strayStart = bulkStart }
                    stray.append(Bulk.preamble)
                    rest = bulk[1...] + rest
                    bulk = []
                    continue
                }
                if bulk.count == Bulk.headerCount + length + 1 {
                    if Aux.checksum(bulk[1..<(bulk.count - 1)]) == bulk[bulk.count - 1] {
                        out.append(.bulk(bytes: bulk, at: bulkStart))
                    } else {
                        out.append(.anomaly(.badChecksum, bytes: bulk, at: bulkStart))
                    }
                    bulk = []
                }
                continue
            }
            if frame.isEmpty {
                if byte == Bulk.preamble {
                    out += takeStray()
                    bulk = [byte]
                    bulkStart = t
                    continue
                }
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
        if !bulk.isEmpty {
            out.append(.anomaly(.truncated, bytes: bulk, at: bulkStart))
            bulk = []
        }
        return out
    }

    private mutating func takeStray() -> [FramerEvent] {
        guard !stray.isEmpty else { return [] }
        defer { stray = [] }
        return [.anomaly(.noise, bytes: stray, at: strayStart)]
    }
}

/// Joins a frame cut short with the broken bytes that follow it soon after
/// into one `.paused` event. On 2026-11-10 the StarSense HC, passing Moon
/// Mosaic's reads through, stopped about 2.5 times a minute after the fifth
/// byte of a request, went quiet for 0.5–1 s, then sent the checksum and
/// often the request again with `00` for its checksum; the motor answered
/// after that. The framer saw each as cut short, stray bytes and a bad
/// checksum. A cut-short frame with nothing broken after it within
/// `windowNs` is passed on as it was.
public struct PauseJoiner: Sendable {
    public var windowNs: UInt64

    private var held: (bytes: [UInt8], at: UInt64, lastAt: UInt64, parts: Int)?

    public init(windowNs: UInt64 = 1_500_000_000) {
        self.windowNs = windowNs
    }

    /// Feed it the framer's events, and call it on a timer (with none) so a
    /// held frame is let go once its window is over.
    public mutating func process(_ events: [FramerEvent], at now: UInt64) -> [FramerEvent] {
        var out: [FramerEvent] = []
        for event in events {
            if case .anomaly(let kind, let bytes, let at) = event, kind != .noReply {
                if var h = held, at >= h.at, at - h.at <= windowNs {
                    h.bytes += bytes
                    h.lastAt = at
                    h.parts += 1
                    held = h
                    continue
                }
                out += release()
                if kind == .truncated {
                    held = (bytes, at, at, 1)
                } else {
                    out.append(event)
                }
                continue
            }
            // A packet after the broken bytes ends the episode.
            if let h = held, h.parts > 1, case .packet = event {
                out += release()
            }
            out.append(event)
        }
        if let h = held, now >= h.at, now - h.at > windowNs {
            out += release()
        }
        return out
    }

    private mutating func release() -> [FramerEvent] {
        guard let h = held else { return [] }
        held = nil
        return h.parts == 1
            ? [.anomaly(.truncated, bytes: h.bytes, at: h.at)]
            : [.paused(bytes: h.bytes, at: h.at, resumedAt: h.lastAt)]
    }
}
