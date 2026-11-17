import Foundation

/// An expanding square spiral of search positions for finding the Moon when
/// it is near but not yet in the camera's field (ADR 0022). The operator gets
/// close with the spotting scope; this walks the small remaining uncertainty,
/// one short move at a time, watching the frame's brightness.
///
/// Positions are offsets from where the search started, in **mount-axis
/// degrees**: `azDeg` on the azimuth axis, `altDeg` on altitude. The spiral
/// steps by `stepDeg` and stops once a ring would pass `reachDeg` from the
/// start on both axes. Set `stepDeg` below the camera's short field so the
/// Moon's bright disk can't be stepped over; since the Moon (~0.5°) is far
/// larger than the field (~5–9′), a step a little under the field is safe.
///
/// The order is the classic square spiral — right, up, left, left, down,
/// down, right, right, right, … (arm lengths 1, 1, 2, 2, 3, 3, …) — so each
/// position is **one `stepDeg` move on a single axis** from the one before.
/// That move is given as `axis` + `deltaDeg`, to command as one relative,
/// self-terminating goto (never a timed slew; ADR 0022).
public struct SpiralSearch: Sendable, Equatable {
    /// One stop on the spiral.
    public struct Step: Sendable, Equatable {
        /// Offset from the start, in mount-axis degrees.
        public let azDeg: Double
        public let altDeg: Double
        /// The single-axis move from the previous stop to this one: which
        /// axis, and the signed relative goto in degrees. `deltaDeg` is 0 for
        /// the first stop (the start — capture there before moving).
        public let axis: MountSession.Axis
        public let deltaDeg: Double

        public init(azDeg: Double, altDeg: Double, axis: MountSession.Axis, deltaDeg: Double) {
            self.azDeg = azDeg
            self.altDeg = altDeg
            self.axis = axis
            self.deltaDeg = deltaDeg
        }
    }

    public let stepDeg: Double
    public let reachDeg: Double
    /// The ordered stops, starting at the origin (a no-move capture).
    public let steps: [Step]

    /// `stepDeg`: one move's length. `reachDeg`: how far from the start to
    /// search, on either axis. `maxSteps`: a hard cap so the sequence is
    /// always finite.
    public init(stepDeg: Double, reachDeg: Double, maxSteps: Int = 4096) {
        precondition(stepDeg > 0 && reachDeg >= 0, "stepDeg must be positive, reachDeg non-negative")
        self.stepDeg = stepDeg
        self.reachDeg = reachDeg
        self.steps = Self.build(stepDeg: stepDeg, reachDeg: reachDeg, maxSteps: maxSteps)
    }

    private static func build(stepDeg: Double, reachDeg: Double, maxSteps: Int) -> [Step] {
        // Directions in grid units: az+, alt+, az−, alt−.
        let dirs: [(dx: Int, dy: Int, axis: MountSession.Axis)] = [
            (1, 0, .azimuth), (0, 1, .altitude), (-1, 0, .azimuth), (0, -1, .altitude),
        ]
        var out: [Step] = [Step(azDeg: 0, altDeg: 0, axis: .azimuth, deltaDeg: 0)]
        let reachUnits = reachDeg / stepDeg
        // The spiral only grows, so its in-reach stops are a contiguous prefix:
        // walk until the first stop leaves the reach square, then stop. Arm
        // lengths 1,1,2,2,3,3,…; the ring radius is ⌈armLen/2⌉, so arms run to
        // about 2·reachUnits before every stop is out.
        var (x, y) = (0, 0)
        var dir = 0
        var armLen = 1
        let maxArm = Int(reachUnits.rounded(.up)) * 2 + 2
        while armLen <= maxArm {
            for _ in 0..<2 {
                let d = dirs[dir % 4]
                for _ in 0..<armLen {
                    x += d.dx
                    y += d.dy
                    if Double(max(abs(x), abs(y))) > reachUnits + 1e-9 { return out }
                    out.append(
                        Step(
                            azDeg: Double(x) * stepDeg,
                            altDeg: Double(y) * stepDeg,
                            axis: d.axis,
                            deltaDeg: Double(d.dx + d.dy) * stepDeg
                        ))
                    if out.count >= maxSteps { return out }
                }
                dir += 1
            }
            armLen += 1
        }
        return out
    }
}
