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
        let a = Self.moonAxes(at: time.addingTimeInterval(-15), settings.site)
        let b = Self.moonAxes(at: time.addingTimeInterval(15), settings.site)
        return (wrap180(b.az - a.az) / 30, (b.alt - a.alt) / 30)
    }

    func offset(of p: [Double], at time: Date) -> FollowState.Offset {
        let m = Self.moonAxes(at: time, settings.site)
        return FollowState.Offset(az: wrap180(p[0] - m.az), alt: p[1] - m.alt)
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

    /// A goto back to `back` against the Moon, aimed a moment ahead.
    private func undo(to back: FollowState.Offset) async throws {
        let lead = 3.0
        let m = Self.moonAxes(at: clock().addingTimeInterval(lead), settings.site)
        try await armForStep()
        defer { endStep() }
        for (axis, target) in [
            (MountSession.Axis.azimuth, Ephemeris.normalize(m.az + back.az)), (.altitude, m.alt + back.alt),
        ] {
            try await moveAxis(axis, to: target, approach: nil)
        }
    }
}
