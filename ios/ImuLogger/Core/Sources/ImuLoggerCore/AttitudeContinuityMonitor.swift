/// Flags attitude jumps that the measured rotation rate can't explain, such as
/// a Core Motion reset after an interruption. Analysis segments the session at
/// these points instead of joining across them.
public struct AttitudeContinuityMonitor: Sendable {
    public struct Discontinuity: Equatable, Sendable {
        public var seq: Seq
        public var tNs: Nanos
        public var jumpRad: Double
        public var explainedRad: Double
        public var gapNs: Nanos
    }

    /// Extra angle allowed beyond what the rotation rate explains.
    public var toleranceRad: Double
    /// Rotation-rate integration is scaled by this factor to allow for noise.
    public var rateMargin: Double

    private var last: (q: Quaternion, tNs: Nanos, rate: Double)?

    public init(toleranceRad: Double = 0.02, rateMargin: Double = 2) {
        self.toleranceRad = toleranceRad
        self.rateMargin = rateMargin
    }

    public mutating func check(_ sample: DeviceMotionSample) -> Discontinuity? {
        let rate = sample.rotationRate.magnitude
        defer { last = (sample.attitude, sample.tNs, rate) }
        guard let last else { return nil }
        let gap = sample.tNs - last.tNs
        guard let jump = last.q.angle(to: sample.attitude) else { return nil }
        let explained = max(rate, last.rate) * Double(max(gap, 0)) / 1e9 * rateMargin
        guard gap <= 0 || jump > explained + toleranceRad else { return nil }
        return Discontinuity(
            seq: sample.seq, tNs: sample.tNs, jumpRad: jump, explainedRad: explained, gapNs: gap)
    }
}
