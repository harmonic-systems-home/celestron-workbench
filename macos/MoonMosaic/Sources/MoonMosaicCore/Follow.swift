import Foundation

/// Follow mode (ADR 0022 amendment 7): tracking is the baseline. The mount
/// runs at the Moon's rate from the moment Track is pressed (no Here
/// needed: the rates come from the ephemeris alone). Wherever a nudge
/// leaves the scope, it stays. Every nudge, from the hand controller or the
/// app, goes on an undo stack, and Undo returns to the position before it
/// *relative to the Moon* (where the Moon has moved on to, not the old
/// encoder angles), then tracks on.
public final class FollowState: @unchecked Sendable {
    private let lock = NSLock()
    private var _active = false
    private var _undo: [Offset] = []
    private var _requests: [Request] = []
    private var _nudging = false

    /// Where the scope points against the Moon, in axis degrees: the mount's
    /// axes minus the Moon's computed azimuth and altitude at that moment.
    /// The encoders' own zero cancels out, so this needs no Here.
    public struct Offset: Sendable, Equatable {
        public let az: Double
        public let alt: Double
    }

    enum Request {
        /// Move by this much on the sky (arcseconds, x along azimuth, y up).
        case nudge(SkyOffset)
        case stop
        case undo
    }

    public var active: Bool { lock.withLock { _active } }
    public var undoDepth: Int { lock.withLock { _undo.count } }
    /// A nudge is in progress (seen on the encoders, or commanded).
    public var nudging: Bool { lock.withLock { _nudging } }

    func setActive(_ a: Bool) { lock.withLock { _active = a } }
    func setNudging(_ n: Bool) { lock.withLock { _nudging = n } }
    func push(_ o: Offset) {
        lock.withLock {
            _undo.append(o)
            if _undo.count > 50 { _undo.removeFirst() }
        }
    }
    func pop() -> Offset? { lock.withLock { _undo.popLast() } }
    func request(_ r: Request) { lock.withLock { _requests.append(r) } }
    func takeRequests() -> [Request] {
        lock.withLock {
            defer { _requests = [] }
            return _requests
        }
    }
}

extension MosaicSession {
    /// The Moon's computed azimuth and altitude (degrees) at `time`.
    static func moonAxes(at time: Date, _ site: Site) -> (az: Double, alt: Double) {
        let h = Ephemeris.moon(at: time, from: site).horizontal
        return (h.azDeg, h.altDeg)
    }

    /// The Moon's rate on each axis now (deg/s), from the ephemeris over ±15 s.
    func moonRate(at time: Date) -> (az: Double, alt: Double) {
        let a = modelMoon(at: time.addingTimeInterval(-15))
        let b = modelMoon(at: time.addingTimeInterval(15))
        return (wrap180(b.az - a.az) / 30, (b.alt - a.alt) / 30)
    }

    func offset(of p: [Double], at time: Date) -> FollowState.Offset {
        let m = modelMoon(at: time)
        // Both wrapped: before Here the altitude encoder can read near 360.
        return FollowState.Offset(az: wrap180(p[0] - m.az), alt: wrap180(p[1] - m.alt))
    }

    // MARK: Requests (from the app, while the follow loop runs)

    /// Nudges the scope by `sky` (arcseconds on the sky), on top of tracking.
    public func followNudge(_ sky: SkyOffset) { follow.request(.nudge(sky)) }
    /// Ends a nudge: the extra rate stops, tracking carries on.
    public func followStop() { follow.request(.stop) }
    /// Back to where the scope was against the Moon before the last nudge.
    public func followUndo() { follow.request(.undo) }

    /// Runs Follow until `cancelled`: tracks at the Moon's rate, watches the
    /// encoders for nudges (motion off the tracking path), and carries out
    /// the app's nudge, Stop and Undo requests. Tracking keeps running when
    /// this returns; Stop Tracking (or any arm) ends it.
    public func runFollow(cancelled: @escaping @Sendable () -> Bool) async throws {
        follow.setActive(true)
        defer { follow.setActive(false) }
        if (try? mount.status().state) == "Armed" { endStep() }
        var rate = moonRate(at: clock())
        try mount.track(azDegS: rate.az, altDegS: rate.alt)
        var rateSet = Date()
        // The tracking path: where the encoders should be, from a reference.
        var ref = (time: clock(), p: try await freshPosition())
        // Track starts with the scope on the Moon (the spotting scope on it).
        if sun.onMoon == nil { markOnMoon(ref.p, at: ref.time) }
        var lastSunCheck = Date.distantPast
        var lastOnPath = offset(of: ref.p, at: ref.time)
        var offPathSince: Date?
        var settledSince: Date?
        var last = ref
        // A commanded nudge: its extra rate ends at this time.
        var nudgeEnds: Date?
        // Arcseconds on the sky off the path that counts as a nudge.
        let threshold = 20.0

        func path(at t: Date) -> [Double] {
            let dt = t.timeIntervalSince(ref.time)
            return [ref.p[0] + rate.az * dt, ref.p[1] + rate.alt * dt]
        }
        func skyDistance(_ a: [Double], _ b: [Double], _ alt: Double) -> Double {
            hypot(wrap180(a[0] - b[0]) * cos(alt * .pi / 180), a[1] - b[1]) * 3600
        }
        func resetPath() async throws {
            ref = (clock(), try await freshPosition())
            last = ref
            lastOnPath = offset(of: ref.p, at: ref.time)
            offPathSince = nil
            settledSince = nil
        }

        while !cancelled() {
            let now = clock()
            // The rates drift slowly with the Moon's position: refresh.
            if now.timeIntervalSince(rateSet) > 10, nudgeEnds == nil, !follow.nudging {
                rate = moonRate(at: now)
                try mount.track(azDegS: rate.az, altDegS: rate.alt)
                rateSet = now
                try await resetPath()
            }
            for request in follow.takeRequests() {
                switch request {
                case .nudge(let sky):
                    if nudgeEnds == nil { follow.push(lastOnPath) }
                    // The sky's altitude (the Moon's), not the encoder's:
                    // before Here the encoder's altitude is arbitrary.
                    let alt = Self.moonAxes(at: clock(), settings.site).alt
                    let axes = MosaicPlanner.axes(for: sky, altitudeDeg: alt)
                    // At 0.1°/s on the sky (half a second at least): a
                    // quarter frame takes half a second.
                    let distance = hypot(axes.azDeg * cos(alt * .pi / 180), axes.altDeg)
                    let seconds = max(0.5, distance / 0.1)
                    if let p = try? mount.status().positionsDeg {
                        do {
                            try checkSun(from: p, to: [p[0] + axes.azDeg, p[1] + axes.altDeg], what: "the nudge")
                        } catch {
                            onEvent(.message("\(error)"))
                            continue
                        }
                    }
                    try mount.track(
                        azDegS: rate.az + axes.azDeg / seconds, altDegS: rate.alt + axes.altDeg / seconds)
                    nudgeEnds = clock().addingTimeInterval(seconds)
                    follow.setNudging(true)
                case .stop:
                    try mount.track(azDegS: rate.az, altDegS: rate.alt)
                    nudgeEnds = nil
                    follow.setNudging(false)
                    try await resetPath()
                    onEvent(.message("Follow: stopped; tracking on."))
                case .undo:
                    guard let back = follow.pop() else {
                        onEvent(.message("Follow: nothing to undo."))
                        continue
                    }
                    nudgeEnds = nil
                    follow.setNudging(false)
                    try await undo(to: back)
                    rate = moonRate(at: clock())
                    try mount.track(azDegS: rate.az, altDegS: rate.alt)
                    rateSet = clock()
                    try await resetPath()
                    onEvent(
                        .message(
                            "Follow: back to where it was against the Moon before the last nudge (\(follow.undoDepth) more to undo)."
                        ))
                }
            }
            if let end = nudgeEnds, clock() >= end {
                try mount.track(azDegS: rate.az, altDegS: rate.alt)
                nudgeEnds = nil
                follow.setNudging(false)
                try await Task.sleep(for: .milliseconds(300))
                try await resetPath()
            }
            // Watch for motion the app didn't command (the hand controller).
            if let p = try? mount.status().positionsDeg, Date().timeIntervalSince(lastSunCheck) > 1 {
                lastSunCheck = Date()
                watchSun(p)
            }
            if nudgeEnds == nil, let p = try mount.status().positionsDeg {
                let t = clock()
                let skyAlt = Self.moonAxes(at: t, settings.site).alt
                let off = skyDistance(p, path(at: t), skyAlt)
                if off > threshold {
                    if offPathSince == nil {
                        offPathSince = t
                        follow.push(lastOnPath)
                        follow.setNudging(true)
                        onEvent(.message("Follow: a nudge from the hand controller; Undo goes back to before it."))
                    }
                    // Settled again when it moves at the Moon's rate.
                    let dt = t.timeIntervalSince(last.time)
                    if dt > 0.05 {
                        let moved = skyDistance(p, [last.p[0] + rate.az * dt, last.p[1] + rate.alt * dt], skyAlt)
                        if moved / dt < 5 {
                            if settledSince == nil { settledSince = t }
                            if t.timeIntervalSince(settledSince!) > 0.6 {
                                follow.setNudging(false)
                                try await resetPath()
                                continue
                            }
                        } else {
                            settledSince = nil
                        }
                        last = (t, p)
                    }
                } else {
                    lastOnPath = offset(of: p, at: t)
                    last = (t, p)
                }
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    /// Waits (up to `maxSeconds`) until both axes run at the Moon's rate
    /// again. The mount ramps rates at only ~2.7°/s², so after a 1.9°/s move
    /// it coasts on for most of a second and over half a degree
    /// (2026-11-20, first raster night: a read taken mid-coast sent the
    /// return to a sighting 0.46° off and lost the Moon every time).
    func waitUntilSettled(maxSeconds: Double = 3) async throws {
        let end = Date().addingTimeInterval(maxSeconds)
        var last: (wall: Date, p: [Double])?
        var calm = 0
        while Date() < end {
            if let st = try? mount.status(), let p = st.positionsDeg, let age = st.positionsAgeMs {
                let wall = Date().addingTimeInterval(-Double(age) / 1000)
                if let l = last, wall.timeIntervalSince(l.wall) > 0.15 {
                    let dt = wall.timeIntervalSince(l.wall)
                    let r = moonRate(at: clock())
                    let vAz = wrap180(p[0] - l.p[0]) / dt - r.az
                    let vAlt = wrap180(p[1] - l.p[1]) / dt - r.alt
                    calm = abs(vAz) < 0.03 && abs(vAlt) < 0.03 ? calm + 1 : 0
                    if calm >= 2 { return }
                    last = (wall, p)
                } else if last == nil {
                    last = (wall, p)
                }
            }
            try await Task.sleep(for: .milliseconds(80))
        }
    }

    /// A straight move to axis angles `target` (the Moon-relative point a
    /// moment ahead), which moves on with the Moon: see `rateMove(aim:)`.
    func rateMove(
        to target: (az: Double, alt: Double), speedDegS: Double = 1.5, toleranceDeg: Double = 0.02,
        trackingWay: Bool = false
    ) async throws {
        let started = clock()
        let r = moonRate(at: started)
        try await rateMove(
            aim: { t in
                let since = t.timeIntervalSince(started)
                return (target.az + r.az * since, target.alt + r.alt * since)
            }, speedDegS: speedDegS, toleranceDeg: toleranceDeg, trackingWay: trackingWay)
    }

    /// A move to `sky` (relative to the Moon's centre), the aim taken
    /// afresh from the Moon model before every leg.
    func rateMove(
        toSky sky: SkyOffset, speedDegS: Double = 1.5, toleranceDeg: Double = 0.02, trackingWay: Bool = true
    ) async throws {
        try await rateMove(
            aim: { try self.target(sky, at: $0) }, speedDegS: speedDegS, toleranceDeg: toleranceDeg,
            trackingWay: trackingWay)
    }

    /// How far past its aim an axis goes, to come back the way it tracks:
    /// past the gears' backlash (azimuth 245″, altitude 70–120″;
    /// observations O9, O13), axis degrees.
    static let tackDeg = 0.1

    /// A straight move to `aim(t)`, the axis angles to be at, at session time
    /// `t`: extra tracking rate on both axes together for as long as the
    /// move takes at `speedDegS` on the sky, then tracking on. Fast (the
    /// firmware's slow goto crawls) and cross-coupled, and tracking never
    /// stops. It waits for the mount to settle before measuring and after
    /// moving, then corrects at a gentler speed until within `toleranceDeg`
    /// on the sky (the ramp and coast make a single open-loop move tenths
    /// of a degree off).
    ///
    /// With `trackingWay`, each axis's last leg turns its motor the way it
    /// tracks: an axis that must go back goes `tackDeg` past and returns.
    /// A reversal leaves the gears' slack on the other side, which the motor
    /// encoders count but the tube doesn't follow, and the tracking then
    /// takes it up with the tube standing still; and the hand controller's
    /// anti-backlash kicks the axis on a reversal (2026-11-20, first night:
    /// the nudge's image moved 1.75× as far as commanded).
    func rateMove(
        aim: (Date) throws -> (az: Double, alt: Double), speedDegS: Double, toleranceDeg: Double,
        trackingWay: Bool
    ) async throws {
        if (try? mount.status().state) == "Armed" { endStep() }
        // Each axis: did its last leg turn the motor against the tracking?
        var against = [false, false]
        var tacks = [0, 0]
        // The last leg: where it started, when, what it asked, how long.
        var leg: (p: [Double], wall: Date, d: [Double], seconds: Double, r: (az: Double, alt: Double))?
        for attempt in 0..<6 {
            try await waitUntilSettled()
            var p = try await freshPosition()
            if let st = try? mount.status(), let q = st.positionsDeg, let age = st.positionsAgeMs {
                let r = st.tracking ?? [0, 0]
                p = [q[0] + r[0] * Double(age) / 1000, q[1] + r[1] * Double(age) / 1000]
            }
            let pWall = Date()
            if let l = leg {
                // How far the leg really went along its way, less the
                // tracking's share: a leg runs on past its time for the
                // command's latency (the test runner: ~25″ long at 0.35°/s,
                // so every return from going past went past again).
                let dt = pWall.timeIntervalSince(l.wall)
                let moved = [wrap180(p[0] - l.p[0]) - l.r.az * dt, wrap180(p[1] - l.p[1]) - l.r.alt * dt]
                let n = hypot(l.d[0], l.d[1])
                if n > 0.02 {
                    let along = (moved[0] * l.d[0] + moved[1] * l.d[1]) / n
                    let extra = (along - n) / (n / l.seconds)
                    legLatency = min(0.3, max(-0.2, 0.5 * legLatency + 0.5 * extra))
                }
            }
            let a = try aim(clock())
            let alt = Self.moonAxes(at: clock(), settings.site).alt
            let cosAlt = cos(alt * .pi / 180)
            var d = [wrap180(a.az - p[0]), wrap180(a.alt - p[1])]
            let sky = hypot(d[0] * cosAlt, d[1])
            let r = moonRate(at: clock())
            let tolerance = attempt == 0 ? 1.0 / 3600 : toleranceDeg
            if sky < tolerance && !(trackingWay && against.contains(true)) { break }
            if attempt == 0 { try checkSun(from: p, to: [p[0] + d[0], p[1] + d[1]], what: "the move") }
            if trackingWay {
                let way = [r.az >= 0 ? 1.0 : -1.0, r.alt >= 0 ? 1.0 : -1.0]
                for i in 0..<2 {
                    let need = d[i] * way[i]  // + the tracking's way
                    let k = i == 0 ? cosAlt : 1  // axis degrees to sky
                    if (need < 0 && -need * k > toleranceDeg && tacks[i] < 2) || (against[i] && need < 0.03) {
                        d[i] -= way[i] * Self.tackDeg
                        tacks[i] += 1
                    } else if need < 0 {
                        d[i] = 0  // a little back: left, not reversed for
                    } else if need * k > toleranceDeg {
                        // Aimed a third of the tolerance short: a leg lands
                        // a few arcseconds long as often as short, and long
                        // would mean going back.
                        d[i] -= way[i] * toleranceDeg / 3 / k
                    }
                }
                for i in 0..<2 where d[i] != 0 {
                    if d[i] * way[i] < 0 { against[i] = true } else if d[i] * way[i] >= 0.03 { against[i] = false }
                }
            }
            if ProcessInfo.processInfo.environment["MOSAIC_DEBUG"] != nil {
                onEvent(.message(String(format: "rateMove %d: off %.0f″, leg (%.4f°, %.4f°), latency %.3f s, against %@", attempt, sky * 3600, d[0], d[1], legLatency, "\(against)")))
            }
            if d == [0, 0] { break }
            let legSky = hypot(d[0] * cosAlt, d[1])
            // Corrections gentler: less ramp, less coast.
            let speed = attempt == 0 ? speedDegS : min(speedDegS, 0.5)
            // Within the session's 2°/s on each axis (azimuth runs faster
            // than the sky by 1/cos(altitude)).
            var seconds = max(0.3, legSky / speed)
            seconds = max(seconds, abs(d[0]) / 1.9, abs(d[1]) / 1.9)
            leg = (p, pWall, d, seconds, r)
            try mount.track(azDegS: r.az + d[0] / seconds, altDegS: r.alt + d[1] / seconds)
            try await Task.sleep(for: .seconds(max(0.1, seconds - legLatency)))
            try mount.track(azDegS: r.az, altDegS: r.alt)
            lastMoveEnd = Date()
        }
        try await waitUntilSettled()
        lastMoveEnd = Date()
    }

    /// A move back to `back` against the Moon, tracking all the way.
    private func undo(to back: FollowState.Offset) async throws {
        let m = modelMoon(at: clock())
        if let p = try? mount.status().positionsDeg {
            try checkSun(path: [p, [m.az + back.az, m.alt + back.alt]], what: "Undo")
        }
        try await rateMove(
            aim: { t in
                let m = self.modelMoon(at: t)
                return (Ephemeris.normalize(m.az + back.az), m.alt + back.alt)
            }, speedDegS: 1.5, toleranceDeg: 0.01, trackingWay: true)
    }
}
