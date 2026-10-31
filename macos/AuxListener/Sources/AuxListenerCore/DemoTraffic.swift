/// Made-up bus traffic for trying the app without a cable (ADR 0018): the
/// hand control and the Wi-Fi module poll positions, an arrow key moves
/// azimuth now and then, the Wi-Fi module sends a goto, and once in a while
/// a packet is garbled or a request goes unanswered. Never recorded.
public struct DemoTraffic: Sendable {
    private var now: UInt64 = 0
    private var position: [Double] = [12.34567, 45.67890]
    private var rate: [Double] = [0, 0]
    private var next: [Job: UInt64] = [:]
    private var tick = 0

    private enum Job: CaseIterable, Sendable {
        case handPoll, wifiPoll, keypad, keypadStop, goto, garble, unanswered
    }

    private static let ms: UInt64 = 1_000_000

    public init(start: UInt64) {
        now = start
        next = [
            .handPoll: start + 100 * Self.ms, .wifiPoll: start + 400 * Self.ms,
            .keypad: start + 3_000 * Self.ms, .goto: start + 9_000 * Self.ms,
            .garble: start + 14_000 * Self.ms, .unanswered: start + 21_000 * Self.ms,
        ]
    }

    /// Chunks of bytes, each with the time it arrives, up to `until`.
    public mutating func advance(to until: UInt64) -> [([UInt8], UInt64)] {
        var out: [([UInt8], UInt64)] = []
        while let (job, at) = next.min(by: { $0.value < $1.value }), at <= until {
            for axis in 0..<2 {
                position[axis] += rate[axis] * Double(at - now) / 1e9
            }
            now = at
            next[job] = nil
            out += run(job, at: at)
        }
        return out
    }

    private mutating func run(_ job: Job, at t: UInt64) -> [([UInt8], UInt64)] {
        let hc: UInt8 = 0x0d
        let wifi: UInt8 = 0xb5
        func pair(_ from: UInt8, _ to: UInt8, _ id: UInt8, _ data: [UInt8], _ reply: [UInt8])
            -> [([UInt8], UInt64)]
        {
            [
                (Aux.encode(source: from, destination: to, id: id, data: data), t),
                (Aux.encode(source: to, destination: from, id: id, data: reply), t + 40 * Self.ms),
            ]
        }
        switch job {
        case .handPoll:
            next[.handPoll] = t + 250 * Self.ms
            tick += 1
            let axis: UInt8 = tick % 2 == 0 ? 0x10 : 0x11
            return pair(hc, axis, 0x01, [], units(position[Int(axis - 0x10)]))
        case .wifiPoll:
            next[.wifiPoll] = t + 1_000 * Self.ms
            return pair(wifi, 0x10, 0x01, [], units(position[0]))
                + pair(wifi, 0x10, 0x13, [], [rate[0] == 0 ? 0xFF : 0x00])
        case .keypad:
            next[.keypad] = t + 8_000 * Self.ms
            next[.keypadStop] = t + 1_500 * Self.ms
            rate[0] = 0.0717
            return pair(hc, 0x10, 0x24, [5], [])
        case .keypadStop:
            rate[0] = 0
            return pair(hc, 0x10, 0x24, [0], [])
        case .goto:
            next[.goto] = t + 12_000 * Self.ms
            position[1] += 0.2
            return pair(wifi, 0x11, 0x17, units(position[1]), [])
        case .garble:
            next[.garble] = t + 20_000 * Self.ms
            var bytes = Aux.encode(source: hc, destination: 0x10, id: 0x01)
            bytes[bytes.count - 1] ^= 0x5A
            return [(bytes, t)]
        case .unanswered:
            next[.unanswered] = t + 30_000 * Self.ms
            return [(Aux.encode(source: wifi, destination: 0x11, id: 0xfe), t)]
        }
    }

    private func units(_ deg: Double) -> [UInt8] {
        let u = Int((deg / 360.0 * Aux.unitsPerRev).rounded()) & 0xFF_FFFF
        return [UInt8(u >> 16), UInt8((u >> 8) & 0xFF), UInt8(u & 0xFF)]
    }
}
