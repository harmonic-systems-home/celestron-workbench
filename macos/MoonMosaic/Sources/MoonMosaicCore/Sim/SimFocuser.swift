import Foundation

/// The SCT's focus knob, simulated (ADR 0022 amendment 7). The knob moves
/// the main mirror, which changes three things in the image: the blur away
/// from best focus, the image scale (the focal length changes), and the
/// image's position (the mirror shifts sideways). When the knob reverses,
/// the mirror lags and then jumps (mirror flop). The same interface can
/// stand in for a focus motor later.
public final class SimFocuser: @unchecked Sendable {
    public struct Model: Sendable, Equatable, Codable {
        /// Blur diameter, arcseconds per knob turn from best focus.
        public var blurArcsecPerTurn: Double = 25
        /// Fractional change of the focal length per knob turn.
        public var scalePerTurn: Double = 0.004
        /// The image's sideways shift per knob turn, arcseconds on the sky
        /// (x along azimuth, y along altitude).
        public var shiftArcsecPerTurn: (x: Double, y: Double) = (4, -6)
        /// The extra jump when the knob reverses, arcseconds.
        public var flopArcsec: (x: Double, y: Double) = (8, 12)
        /// Knob travel taken up before the mirror moves, turns.
        public var lashTurns: Double = 0.05

        public init() {}

        public static func == (a: Model, b: Model) -> Bool {
            a.blurArcsecPerTurn == b.blurArcsecPerTurn && a.scalePerTurn == b.scalePerTurn
                && a.shiftArcsecPerTurn == b.shiftArcsecPerTurn && a.flopArcsec == b.flopArcsec
                && a.lashTurns == b.lashTurns
        }

        enum CodingKeys: String, CodingKey {
            case blurArcsecPerTurn, scalePerTurn, shiftX, shiftY, flopX, flopY, lashTurns
        }
        public init(from d: Decoder) throws {
            let c = try d.container(keyedBy: CodingKeys.self)
            blurArcsecPerTurn = try c.decode(Double.self, forKey: .blurArcsecPerTurn)
            scalePerTurn = try c.decode(Double.self, forKey: .scalePerTurn)
            shiftArcsecPerTurn = (try c.decode(Double.self, forKey: .shiftX), try c.decode(Double.self, forKey: .shiftY))
            flopArcsec = (try c.decode(Double.self, forKey: .flopX), try c.decode(Double.self, forKey: .flopY))
            lashTurns = try c.decode(Double.self, forKey: .lashTurns)
        }
        public func encode(to e: Encoder) throws {
            var c = e.container(keyedBy: CodingKeys.self)
            try c.encode(blurArcsecPerTurn, forKey: .blurArcsecPerTurn)
            try c.encode(scalePerTurn, forKey: .scalePerTurn)
            try c.encode(shiftArcsecPerTurn.x, forKey: .shiftX)
            try c.encode(shiftArcsecPerTurn.y, forKey: .shiftY)
            try c.encode(flopArcsec.x, forKey: .flopX)
            try c.encode(flopArcsec.y, forKey: .flopY)
            try c.encode(lashTurns, forKey: .lashTurns)
        }
    }

    public let model: Model
    /// The knob position at which the image is sharpest (hidden from the app).
    public let bestTurns: Double
    private let lock = NSLock()
    private var knob: Double
    /// Where the mirror actually is, in knob turns (lags the knob by the lash).
    private var mirror: Double
    /// The last direction the mirror moved (+1, −1, or 0 before any move),
    /// and the flop state it settled into.
    private var lastDirection = 0.0
    private var flopSide = 0.0

    public init(model: Model = Model(), bestTurns: Double = 0, startTurns: Double = 0) {
        self.model = model
        self.bestTurns = bestTurns
        knob = startTurns
        mirror = startTurns
    }

    /// The knob position, turns.
    public var turns: Double { lock.withLock { knob } }

    /// Turns the knob by `delta` turns (positive clockwise).
    public func turn(by delta: Double) {
        guard delta != 0 else { return }
        lock.withLock {
            knob += delta
            // The mirror follows once the lash is taken up.
            let lash = model.lashTurns
            if knob > mirror + lash / 2 {
                mirror = knob - lash / 2
                move(+1)
            } else if knob < mirror - lash / 2 {
                mirror = knob + lash / 2
                move(-1)
            }
        }
    }

    private func move(_ direction: Double) {
        if direction != lastDirection {
            // A reversal: the mirror tips onto its other side.
            flopSide = direction
            lastDirection = direction
        }
    }

    /// What the mirror's position does to the image now.
    public struct Effect: Sendable {
        /// Blur diameter, arcseconds.
        public let blurArcsec: Double
        /// Scale factor on the image (1 at the start position).
        public let scale: Double
        /// The image's offset on the sky, arcseconds.
        public let shift: (x: Double, y: Double)
    }

    public var effect: Effect {
        lock.withLock {
            let m = mirror
            return Effect(
                blurArcsec: abs(m - bestTurns) * model.blurArcsecPerTurn,
                scale: 1 + model.scalePerTurn * m,
                shift: (
                    model.shiftArcsecPerTurn.x * m + model.flopArcsec.x * flopSide / 2,
                    model.shiftArcsecPerTurn.y * m + model.flopArcsec.y * flopSide / 2
                ))
        }
    }
}
