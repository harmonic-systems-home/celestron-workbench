import Foundation

/// Sun avoidance (ADR 0022 amendment 7): while the Sun is up, every move the
/// app commands, along its whole path, and every search area keep at least
/// the minimum separation from the Sun. The pointing is known against the
/// Moon (the follow offsets), so this needs no Here: the sky direction is the
/// Moon's computed position plus how far the scope is from where it was
/// last on the Moon.
public final class SunGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var _onMoon: FollowState.Offset?
    private var _override: Double?
    private var _warned = false

    /// Above this altitude (degrees) the Sun counts as up: its disk plus
    /// refraction.
    public static let upAltitudeDeg = -2.0

    /// The follow offset (axes minus the Moon's az/alt) when the scope was
    /// last on the Moon: at Track, a sighting, Here or the centre fit.
    public var onMoon: FollowState.Offset? { lock.withLock { _onMoon } }
    func setOnMoon(_ o: FollowState.Offset) { lock.withLock { _onMoon = o } }

    /// The operator's override for sunrise and sunset, for this session
    /// only (never saved): a lower separation in degrees, 0 for off. Nil is
    /// the setting's own minimum.
    public var overrideDeg: Double? {
        get { lock.withLock { _override } }
        set { lock.withLock { _override = newValue } }
    }

    /// Whether the warning for the current pointing was given (so the
    /// monitor warns once each time the pointing comes too close).
    func warn(_ close: Bool) -> Bool {
        lock.withLock {
            defer { _warned = close }
            return close && !_warned
        }
    }
}

public struct SunTooClose: Error, CustomStringConvertible {
    public let separationDeg: Double
    public let limitDeg: Double
    public let what: String
    public var description: String {
        String(
            format:
                "Refused (Sun avoidance): %@ would point %.0f° from the Sun, inside the %.0f° limit. Settings has an override for sunrise and sunset.",
            what, separationDeg, limitDeg)
    }
}

extension MosaicSession {
    /// The Sun's (geometric) azimuth and altitude now.
    func sunHorizontal(at t: Date) -> Horizontal {
        Ephemeris.horizontal(Ephemeris.sun(at: t), at: t, from: settings.site)
    }

    /// The limit in force (degrees), or nil while the Sun is down or the
    /// override turns the check off.
    func sunLimit(at t: Date) -> Double? {
        guard sunHorizontal(at: t).altDeg > SunGuard.upAltitudeDeg else { return nil }
        let limit = sun.overrideDeg ?? settings.minSunSeparationDeg
        return limit > 0 ? limit : nil
    }

    /// Where axis angles `p` point on the sky at `t`: the Moon plus the
    /// scope's offset from where it was last on the Moon.
    func skyDirection(of p: [Double], at t: Date) -> Horizontal {
        let o = offset(of: p, at: t)
        let ref = sun.onMoon ?? o
        let m = Self.moonAxes(at: t, settings.site)
        return Horizontal(azDeg: Ephemeris.normalize(m.az + o.az - ref.az), altDeg: m.alt + o.alt - ref.alt)
    }

    /// Degrees between two alt-az directions.
    static func angleDeg(_ a: Horizontal, _ b: Horizontal) -> Double {
        let (a1, h1, a2, h2) = (deg2rad(a.azDeg), deg2rad(a.altDeg), deg2rad(b.azDeg), deg2rad(b.altDeg))
        let c = sin(h1) * sin(h2) + cos(h1) * cos(h2) * cos(a1 - a2)
        return rad2deg(acos(min(1, max(-1, c))))
    }

    /// How far axis angles `p` point from the Sun at `t`.
    func sunSeparationDeg(of p: [Double], at t: Date) -> Double {
        Self.angleDeg(skyDirection(of: p, at: t), sunHorizontal(at: t))
    }

    /// Notes where the scope is on the Moon now (Track, a sighting, Here).
    func markOnMoon(_ p: [Double], at t: Date) {
        sun.setOnMoon(offset(of: p, at: t))
    }

    /// Throws if any point of the straight path (in axis angles) from `a`
    /// to `b` comes inside the limit while the Sun is up.
    func checkSun(from a: [Double], to b: [Double], what: String) throws {
        let t = clock()
        guard let limit = sunLimit(at: t) else { return }
        if sun.onMoon == nil { markOnMoon(a, at: t) }
        let dAz = wrap180(b[0] - a[0])
        let dAlt = wrap180(b[1] - a[1])
        let n = max(1, Int((max(abs(dAz), abs(dAlt)) / 0.5).rounded(.up)))
        var worst = Double.infinity
        for k in 0...n {
            let f = Double(k) / Double(n)
            worst = min(worst, sunSeparationDeg(of: [a[0] + dAz * f, a[1] + dAlt * f], at: t))
        }
        if worst < limit { throw SunTooClose(separationDeg: worst, limitDeg: limit, what: what) }
    }

    /// Checks a whole area: a list of axis-angle points, joined in order.
    func checkSun(path: [[Double]], what: String) throws {
        for (a, b) in zip(path, path.dropFirst()) { try checkSun(from: a, to: b, what: what) }
        if path.count == 1 { try checkSun(from: path[0], to: path[0], what: what) }
    }

    /// The monitor's check of the current pointing (hand-controller moves
    /// can't be refused): warns once each time it comes inside the limit.
    func watchSun(_ p: [Double]) {
        let t = clock()
        guard let limit = sunLimit(at: t) else {
            _ = sun.warn(false)
            return
        }
        let sep = sunSeparationDeg(of: p, at: t)
        if sun.warn(sep < limit) {
            onEvent(
                .message(
                    String(
                        format:
                            "WARNING (Sun): the scope now points %.0f° from the Sun, inside the %.0f° limit. Move it away from the Sun now.",
                        sep, limit)))
        }
    }
}
