import Foundation

/// The Moon model's drift correction. The app knows where the Moon is from
/// the ephemeris and the mount's encoders; when the mount isn't level (or
/// the site or clock is a little off) the real Moon slides away from that
/// model, steadily: 2026-11-20, first night, 1–2″/s, so a capture planned
/// from a centre found minutes earlier ended up 1,300″ off.
///
/// The correction is a bias added to the ephemeris's axis angles,
/// growing at a measured rate: `bias(t) = base + rate · (t − since)`. Each
/// new measurement adds to the rate and keeps the bias continuous, so
/// everything already known relative to the Moon (Here, the centre) stays
/// where it was at that moment.
public final class MoonModelDrift: @unchecked Sendable {
    private let lock = NSLock()
    private var base = (az: 0.0, alt: 0.0)
    private var rate = (az: 0.0, alt: 0.0)
    private var since: Date?
    private var _measured: Date?

    public init() {}

    /// When the drift was last measured (the session's clock).
    public var measured: Date? { lock.withLock { _measured } }

    /// The bias (degrees on each axis) at `t`.
    public func bias(at t: Date) -> (az: Double, alt: Double) {
        lock.withLock {
            guard let since else { return (0, 0) }
            let dt = t.timeIntervalSince(since)
            return (base.az + rate.az * dt, base.alt + rate.alt * dt)
        }
    }

    /// The bias's rate (degrees per second on each axis).
    public var ratePerSecond: (az: Double, alt: Double) { lock.withLock { rate } }

    /// Adds `extra` (deg/s on each axis) to the rate from `t` on.
    public func addRate(_ extra: (az: Double, alt: Double), at t: Date) {
        lock.withLock {
            if let since {
                let dt = t.timeIntervalSince(since)
                base = (base.az + rate.az * dt, base.alt + rate.alt * dt)
            }
            rate = (rate.az + extra.az, rate.alt + extra.alt)
            since = t
            _measured = t
        }
    }

    /// Forgets the correction (a new session, or Here pressed afresh).
    public func reset() {
        lock.withLock {
            base = (0, 0)
            rate = (0, 0)
            since = nil
        }
    }
}

extension MosaicSession {
    /// The ephemeris's offset of axis angles `p` from the Moon at `time`, with
    /// no drift correction: for the simulator's truth.
    public static func ephemerisOffset(of p: [Double], at time: Date, _ site: Site) -> FollowState.Offset {
        let m = moonAxes(at: time, site)
        return FollowState.Offset(az: wrap180(p[0] - m.az), alt: wrap180(p[1] - m.alt))
    }

    /// The least-squares line through (t, x, y): its slope on each, and the
    /// RMS scatter about it.
    static func slope(_ v: [(t: Double, x: Double, y: Double)]) -> (x: Double, y: Double, scatter: Double) {
        guard v.count >= 2 else { return (0, 0, 0) }
        let n = Double(v.count)
        let mt = v.map(\.t).reduce(0, +) / n
        let mx = v.map(\.x).reduce(0, +) / n
        let my = v.map(\.y).reduce(0, +) / n
        let stt = v.map { ($0.t - mt) * ($0.t - mt) }.reduce(0, +)
        guard stt > 0 else { return (0, 0, 0) }
        let kx = v.map { ($0.t - mt) * ($0.x - mx) }.reduce(0, +) / stt
        let ky = v.map { ($0.t - mt) * ($0.y - my) }.reduce(0, +) / stt
        let res = v.map { hypot($0.x - mx - kx * ($0.t - mt), $0.y - my - ky * ($0.t - mt)) }
        return (kx, ky, (res.map { $0 * $0 }.reduce(0, +) / n).squareRoot())
    }

    /// Where the app's model puts the Moon on the mount's axes at `time`:
    /// the ephemeris plus the measured drift.
    func modelMoon(at time: Date) -> (az: Double, alt: Double) {
        let m = Self.moonAxes(at: time, settings.site)
        let b = drift.bias(at: time)
        return (Ephemeris.normalize(m.az + b.az), m.alt + b.alt)
    }

    /// The result of watching the Moon while tracking.
    public struct DriftMeasurement: Sendable {
        /// How the pointing moved against the real Moon, from the image
        /// (arcseconds per second on the sky, x along azimuth).
        public let image: SkyOffset
        /// How it moved against the model's Moon, from the encoders.
        public let encoders: SkyOffset
        /// The model's error added to the correction (image − encoders
        /// turned around: the real Moon's motion against the model).
        public let added: SkyOffset
        /// Frames that matched, and the scatter about the fitted line (″).
        public let frames: Int
        public let scatterArcsec: Double
    }

    /// Tracks the Moon for `seconds`, measures how the image drifts (the
    /// pointing against the real Moon) and how the encoders say the pointing
    /// moved against the model, and adds the difference, the model's error,
    /// to the drift correction. Needs the camera oriented.
    ///
    /// The first second and a half is skipped: the tube settles after a
    /// move (2026-11-20: 17–28″ in the first second of a clip).
    @discardableResult
    public func measureDrift(seconds: Double = 20) async throws -> DriftMeasurement {
        guard let calibration else { throw MosaicError(description: "Orient the camera first.") }
        if (try? mount.status().state) == "Armed" { endStep() }
        try camera.configure(exposureUs: settings.exposureUs, gain: settings.gain)
        try camera.start()
        defer { camera.stop() }
        let r = moonRate(at: clock())
        try mount.track(azDegS: r.az, altDegS: r.alt)
        onEvent(.detail(String(format: "Measuring the tracking's drift: %.0f s, tracking only", seconds)))
        defer { onEvent(.detail(nil)) }
        try await Task.sleep(for: .seconds(max(1.0, 1.5 - Date().timeIntervalSince(lastMoveEnd))))
        let ref = try await grabFrame()
        let refT = clock().addingTimeInterval(ref.time.timeIntervalSinceNow)
        guard let refRead = try? await readAfter(Date().addingTimeInterval(-0.3), limit: 2) else {
            throw MosaicError(description: "No position reads from the mount.")
        }
        let refOffset = offset(of: refRead.p, at: clock().addingTimeInterval(refRead.wall.timeIntervalSinceNow))
        let alt = Self.moonAxes(at: clock(), settings.site).alt
        let cosAlt = cos(alt * .pi / 180)
        var img: [(t: Double, x: Double, y: Double)] = []
        var enc: [(t: Double, x: Double, y: Double)] = []
        let start = Date()
        while Date().timeIntervalSince(start) < seconds {
            try await Task.sleep(for: .milliseconds(400))
            let f = try await grabFrame()
            let t = clock().addingTimeInterval(f.time.timeIntervalSinceNow).timeIntervalSince(refT)
            let s = Registration.shift(from: ref, to: f)
            if s.peak > 0.05 {
                // Features moved by M·(the pointing's move against the Moon).
                let d = calibration.sky(for: PixelOffset(x: s.dx, y: s.dy))
                img.append((t, d.x, d.y))
            }
            if let st = try? mount.status(), let p = st.positionsDeg, let age = st.positionsAgeMs {
                let readT = clock().addingTimeInterval(-Double(age) / 1000)
                let o = offset(of: p, at: readT)
                enc.append(
                    (readT.timeIntervalSince(refT), wrap180(o.az - refOffset.az) * cosAlt * 3600,
                     wrap180(o.alt - refOffset.alt) * 3600))
            }
        }
        guard img.count >= 8, enc.count >= 4 else {
            throw MosaicError(description: "The drift couldn't be followed (\(img.count) frames matched); is Moon detail in view?")
        }
        let slope = Self.slope
        let i = slope(img)
        let e = slope(enc)
        // Pointing − real Moon = (pointing − model) − (real − model): the
        // real Moon moves against the model at (encoders − image).
        let added = SkyOffset(x: e.x - i.x, y: e.y - i.y)
        drift.addRate((az: added.x / cosAlt / 3600, alt: added.y / 3600), at: clock())
        // Tracking on at the corrected rate.
        let r2 = moonRate(at: clock())
        try mount.track(azDegS: r2.az, altDegS: r2.alt)
        let m = DriftMeasurement(
            image: SkyOffset(x: i.x, y: i.y), encoders: SkyOffset(x: e.x, y: e.y), added: added,
            frames: img.count, scatterArcsec: i.scatter)
        let total = drift.ratePerSecond
        note(
            "drift",
            [
                "time": Self.fileStamp(clock()), "seconds": seconds, "frames": img.count,
                "image": [i.x, i.y], "encoders": [e.x, e.y], "added": [added.x, added.y],
                "scatter": i.scatter, "totalDegPerSec": [total.az, total.alt],
            ])
        onEvent(
            .message(
                String(
                    format:
                        "Tracking drift: the Moon slid %.1f″/s against the model (%.1f″/s image, %.1f″/s encoders, %d frames, ±%.1f″); corrected from now.",
                    hypot(added.x, added.y), hypot(i.x, i.y), hypot(e.x, e.y), img.count, i.scatter)))
        return m
    }
}
