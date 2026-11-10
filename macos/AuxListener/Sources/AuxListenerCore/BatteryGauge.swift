import Foundation

// Kept identical in AuxListenerCore and MoonMosaicCore.

/// The mount's battery as a percentage and a projection: time left on
/// battery, or time to full on the charger, from recent readings.
///
/// The NexStar Evolution's battery is lithium iron phosphate (LiFePO4), and
/// the readings fit three cells: 9.70–9.83 V on battery on 2026-11-09. That
/// chemistry's voltage is flat through most of the charge and steep at both
/// ends, so the percentage is an estimate from a generic rest curve, least
/// sure in the middle and read a little low while the motors draw current.
/// While charging the voltage reads high, so no percentage is given then.
public struct BatteryGauge: Sendable {
    /// One reading: the battery's voltage and whether it was charging
    /// (the reply's first byte: 0 on battery, 2 on the charger).
    public struct Sample: Equatable, Sendable {
        public let at: Date
        public let volts: Double
        public let charging: Bool

        public init(at: Date, volts: Double, charging: Bool) {
            self.at = at
            self.volts = volts
            self.charging = charging
        }
    }

    /// Readings this far back feed the projection.
    public var window: TimeInterval = 45 * 60
    /// A projection needs readings spanning at least this long.
    public var minimumSpan: TimeInterval = 10 * 60
    /// Where charging is taken to end: 3.6 V a cell, a typical LiFePO4
    /// charger's limit. Not measured on this mount yet.
    public var fullChargeVolts = 10.8

    private(set) var samples: [Sample] = []

    public init() {}

    /// Per-cell rest voltage → percent, a typical LiFePO4 curve.
    static let curve: [(volts: Double, percent: Double)] = [
        (2.50, 0), (3.00, 10), (3.20, 20), (3.22, 30), (3.25, 40), (3.26, 50),
        (3.27, 60), (3.30, 70), (3.32, 80), (3.35, 90), (3.40, 100),
    ]
    static let cells = 3.0

    /// An estimate, 0–100, from the battery's voltage at rest.
    public static func percent(volts: Double) -> Double {
        let v = volts / cells
        guard let first = curve.first, let last = curve.last else { return 0 }
        if v <= first.volts { return 0 }
        if v >= last.volts { return 100 }
        let i = curve.firstIndex { $0.volts >= v }!
        let (lo, hi) = (curve[i - 1], curve[i])
        return lo.percent + (v - lo.volts) / (hi.volts - lo.volts) * (hi.percent - lo.percent)
    }

    /// Adds a reading. A switch between charging and battery starts afresh.
    public mutating func add(_ sample: Sample) {
        if let last = samples.last, last.charging != sample.charging || sample.at < last.at {
            samples.removeAll()
        }
        samples.append(sample)
        samples.removeAll { sample.at.timeIntervalSince($0.at) > window }
    }

    public var latest: Sample? { samples.last }

    /// On battery: hours left at the recent rate of use. Nil until the
    /// readings span `minimumSpan`, or while the charge isn't measurably
    /// falling.
    public var hoursLeft: Double? {
        guard let last = latest, !last.charging,
            let slope = slope({ Self.percent(volts: $0.volts) }), slope < -0.5
        else { return nil }
        return Self.percent(volts: last.volts) / -slope
    }

    /// On the charger: hours until `fullChargeVolts`, at the recent rate of
    /// rise. Rough: the voltage rises slowly through the middle of a charge
    /// and quickly near the end, so this runs long until near full.
    public var hoursToFull: Double? {
        guard let last = latest, last.charging, let slope = slope({ $0.volts }), slope > 0.001
        else { return nil }
        return max(0, fullChargeVolts - last.volts) / slope
    }

    /// Least-squares slope of `value` per hour over the window.
    private func slope(_ value: (Sample) -> Double) -> Double? {
        guard let first = samples.first, let last = samples.last,
            last.at.timeIntervalSince(first.at) >= minimumSpan
        else { return nil }
        let xs = samples.map { $0.at.timeIntervalSince(first.at) / 3600 }
        let ys = samples.map(value)
        let n = Double(xs.count)
        let mx = xs.reduce(0, +) / n
        let my = ys.reduce(0, +) / n
        let sxx = zip(xs, xs).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - mx) }
        guard sxx > 0 else { return nil }
        let sxy = zip(xs, ys).reduce(0) { $0 + ($1.0 - mx) * ($1.1 - my) }
        return sxy / sxx
    }

    /// "~60%, about 3 h 20 min left" or "Charging, 10.17 V, full in about 2 h (rough)".
    public var summary: String? {
        guard let last = latest else { return nil }
        if last.charging {
            let volts = String(format: "%.2f V", last.volts)
            guard let h = hoursToFull else { return "Charging, \(volts)" }
            return "Charging, \(volts), full in about \(Self.duration(hours: h)) (rough)"
        }
        let p = Int((Self.percent(volts: last.volts) / 10).rounded() * 10)
        guard let h = hoursLeft else { return "~\(p)%" }
        return "~\(p)%, about \(Self.duration(hours: h)) left"
    }

    /// The summary in two parts, for a compact readout: "~60%" and
    /// "about 3 h left", or "Charging" and "10.17 V, full in about 2 h (rough)".
    public var headline: (value: String, detail: String)? {
        guard let summary, let last = latest else { return nil }
        if last.charging {
            return ("Charging", String(summary.dropFirst("Charging, ".count)))
        }
        let parts = summary.split(separator: ",", maxSplits: 1)
        return (
            String(parts[0]),
            parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : String(format: "%.2f V", last.volts)
        )
    }

    /// "45 min", "3 h 20 min", rounded to 10 minutes above an hour.
    static func duration(hours: Double) -> String {
        let minutes = Int((hours * 60).rounded())
        if minutes < 60 { return "\(max(minutes, 1)) min" }
        let rounded = Int((Double(minutes) / 10).rounded()) * 10
        let (h, m) = (rounded / 60, rounded % 60)
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }
}
