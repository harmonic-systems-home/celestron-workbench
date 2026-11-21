import Foundation

public enum DarkTiles: String, Sendable, CaseIterable {
    case auto, include, omit
}

public struct MosaicSettings: Sendable {
    public var site: Site
    /// The telescope's focal length, for the first guess at the image scale.
    public var focalLengthMm: Double = 2000
    public var overlap: Double = 0.25
    /// Extra coverage beyond the computed limb, as a fraction of the radius.
    /// On 2026-11-19 the found centre was ~1000 px off and the limb fell
    /// outside a 3% margin; 20% (about one more ring of tiles) absorbs that.
    public var planMargin: Double = 0.2
    /// Each tile's video. No tracking runs, and the Moon drifts about 15″ a
    /// second, so keep it short; stacking aligns the frames.
    public var videoSeconds: Double = 3
    public var exposureUs: Int = 2_000
    public var gain: Int = 100
    /// Calibration moves, as a fraction of the frame's shorter side.
    public var calibrationFraction: Double = 0.2
    /// Calibration's drift: how long the Moon drifts untracked, and how many
    /// frame-to-frame steps it's measured in.
    public var driftSeconds: Double = 6
    public var driftFrames: Int = 30
    /// How long each calibration move's extra tracking rate runs.
    public var calibrationMoveSeconds: Double = 4
    /// The Moon must be at least this far from the Sun.
    public var minSunSeparationDeg: Double = 40
    /// How long to wait after a goto before using the image.
    public var settleSeconds: Double = 0.7
    /// The survey that finds the Moon's centre (amendment 1): long enough
    /// for earthshine to show above the sky, the sunlit part saturated.
    public var surveyExposureUs: Int = 100_000
    public var surveyGain: Int = 300
    /// How far the survey reaches from Here, in Moon radii. Here only has
    /// to be on the Moon, so 1.5 always reaches past the nearest limb.
    public var surveyReach: Double = 1.5
    /// Survey frames' spacing, in frames.
    public var surveySpacing: Double = 1.4
    /// The dark side's tiles: kept only when earthshine was seen (and never
    /// by day), always kept and shot with the rest, or always left out.
    public var darkTiles: DarkTiles = .auto

    public init(site: Site) {
        self.site = site
    }
}

/// Where the Moon was centred: the starting point for every target.
public struct Here: Sendable {
    public let time: Date
    /// The mount's own axis angles then.
    public let azimuthDeg: Double
    public let altitudeDeg: Double
    /// The Moon as computed for then.
    public let moon: MoonView
}

public enum TileState: Sendable, Equatable {
    case pending, moving, capturing
    case done(file: String, frames: Int, sharpness: Double)
    case failed(String)
}

public enum MosaicEvent: Sendable {
    case message(String)
    case tile(Int, TileState)
    /// Where a search is in its pattern, for the search map.
    case search(SearchProgress)
    /// What the running step is doing now (nil when done), for the status.
    case detail(String?)
}

/// A search's pattern and how far it has got (degrees from where it started,
/// azimuth and altitude axes).
public struct SearchProgress: Sendable {
    public let pattern: [[Double]]
    /// Stops visited so far, with how bright each frame was (0–1).
    public let visited: [[Double]]
    public let brightness: [Double]
    /// The frame's size on the sky, degrees (width, height), and the
    /// altitude, to draw it.
    public let fieldDeg: [Double]
    public let altitudeDeg: Double
    /// Where the search started (azimuth, altitude axis degrees), and when.
    public let start: [Double]
    public let startTime: Date
    /// The pattern moves with the Moon: positions are drawn relative to it.
    public let followsMoon: Bool
    public let finished: Bool
    /// A caption in place of "Stop n of m" (the sweep's rows).
    public var caption: String? = nil
}

public struct MosaicError: Error, CustomStringConvertible {
    public let description: String

    public init(description: String) {
        self.description = description
    }
}

/// The Moon mosaic workflow (ADR 0019): centre by hand, *Here*, calibrate,
/// plan, then for each tile aim from the computed Moon, settle and record a
/// short video. Runs on any `Camera` and any mount session, real or simulated.
public final class MosaicSession: @unchecked Sendable {
    public let mount: MountSession
    public let camera: Camera
    /// Where calibration and survey frames are kept for later review
    /// (2026-11-19: calibration kept failing and nothing was saved to study).
    /// Nil keeps nothing.
    public var diagnostics: URL?
    /// Where Hold and Calibrate aim, relative to the Moon's centre: the
    /// operator pans it from the app (2026-11-19: the hand controller's
    /// arrow keys fought Hold and twice ran away).
    public var aimOffset = SkyOffset(x: 0, y: 0)
    /// Follow mode's state (ADR 0022 amendment 7): tracking, nudges, undo.
    public let follow = FollowState()
    /// The goto in progress, for a progress bar and an ETA.
    public let motion = MotionInfo()
    /// Whether camera frames are being saved, and what for.
    public let saving = SavingInfo()
    /// Sun avoidance: where the scope was last on the Moon, and the override.
    public let sun = SunGuard()
    /// The Moon model's measured drift (the mount not level, and so on).
    public let drift = MoonModelDrift()
    /// When the Moon's centre was last fixed (Orient Moon or a limb check),
    /// on the session's clock.
    public internal(set) var centreFixedAt: Date?
    /// When the last app move ended (wall clock), for waits on the tube's
    /// ringing.
    var lastMoveEnd = Date.distantPast
    /// Searches move their pattern with the Moon (off for a fixed test
    /// target such as the drainpipe).
    public var searchFollowsMoon = false

    /// The sky offset that brings the point at `pixel` (from the frame's
    /// centre) to the centre: calibrated, or the focal-length guess.
    public func panSky(for pixel: PixelOffset) -> SkyOffset { sky(for: pixel, searchOrientation) }
    public private(set) var settings: MosaicSettings
    public internal(set) var here: Here?
    public internal(set) var calibration: CameraCalibration?
    /// The survey's fit, once the centre has been found.
    public private(set) var centreFit: MoonCentre.Fit?
    /// The survey's sunlit cells, relative to the Moon's centre.
    private var litSky: [SkyOffset] = []
    /// Every survey cell, from the Moon's centre in units of its radius, and
    /// whether it was sunlit (for the rotation check).
    private var surveyCells: [(x: Double, y: Double, lit: Bool)] = []
    /// The image orientation a converging search found works before a
    /// calibration (the guess can be mirrored by a star diagonal). Recentre
    /// uses it too.
    public private(set) var searchOrientation: SearchOrientation = .asGuessed
    public private(set) var plan: MosaicPlan?
    /// The dark tiles not yet done, for an earthshine pass.
    public var darkTilesToDo: [Int] {
        (plan?.tiles ?? []).filter { !$0.lit }.map(\.id).filter {
            if case .done = states[$0] { return false } else { return true }
        }
    }
    /// The folder whose session log has this plan in it.
    private var loggedPlanIn: URL?
    public private(set) var states: [Int: TileState] = [:]
    /// Each finished tile's quick stack, for the preview.
    public private(set) var stacks: [Int: QuickStack] = [:]
    /// Each axis finishes its gotos moving the way the Moon drifts on it,
    /// so touch-ups after a goto are single short legs (set at Here).
    private var approach: (az: MountSession.Direction, alt: MountSession.Direction) = (
        .positive, .positive
    )
    let clock: @Sendable () -> Date
    /// The session's time (the rehearsal clock when simulating).
    public var now: Date { clock() }
    let onEvent: @Sendable (MosaicEvent) -> Void

    public init(
        mount: MountSession, camera: Camera, settings: MosaicSettings,
        clock: @escaping @Sendable () -> Date = { Date() },
        onEvent: @escaping @Sendable (MosaicEvent) -> Void = { _ in }
    ) {
        self.mount = mount
        self.camera = camera
        self.settings = settings
        self.clock = clock
        self.onEvent = onEvent
    }

    // MARK: Here

    /// New exposure and gain, for the next step (they're set on the camera
    /// as each step starts).
    /// Rehearsing faster: waits meant for the real mount's settling are
    /// shortened by `factor` (the simulated mount's gotos speed up to match).
    public func setTimeScale(_ factor: Double) {
        if baseSettle == nil { baseSettle = settings.settleSeconds }
        settings.settleSeconds = (baseSettle ?? settings.settleSeconds) / max(factor, 0.1)
    }
    private var baseSettle: Double?

    /// The sunlit part's outline in the plan's pixels (the camera frame,
    /// from the Moon's centre), for drawing over the tiles; nil before the
    /// camera is oriented and the Moon placed.
    public func litOutlineInPlan() -> [PixelOffset]? {
        guard let calibration, let here else { return nil }
        let phase = Ephemeris.phase(at: clock(), from: settings.site)
        let r = here.moon.diameterDeg / 2 * 3600
        return Ephemeris.litOutline(
            brightLimbFromZenithDeg: phase.brightLimbFromZenithDeg, phaseAngleDeg: phase.phaseAngleDeg
        ).map {
            // A part of the Moon at sky offset s shows at −M·s.
            let p = calibration.image(for: SkyOffset(x: $0.x * r, y: $0.y * r))
            return PixelOffset(x: -p.x, y: -p.y)
        }
    }

    /// What happens to the dark side's tiles (for the next Plan).
    public func setDarkTiles(_ d: DarkTiles) { settings.darkTiles = d }

    /// Sun avoidance's minimum separation (degrees).
    public func setSunLimit(_ deg: Double) { settings.minSunSeparationDeg = deg }

    public func setCamera(exposureUs: Int, gain: Int) {
        settings.exposureUs = exposureUs
        settings.gain = gain
    }

    /// The survey's exposure and gain, for the next survey.
    public func setSurvey(exposureUs: Int, gain: Int) {
        settings.surveyExposureUs = exposureUs
        settings.surveyGain = gain
    }

    /// Records where the Moon is centred, checks the Sun and ties the
    /// altitude encoder to the Moon's altitude. It doesn't arm the mount:
    /// each step arms it for its own moves (`armForStep`), so the hand
    /// controller's keys stay free between steps, and moving with them
    /// leaves Here good (the encoders see the move).
    public func markHere() async throws {
        aimOffset = SkyOffset(x: 0, y: 0)
        let now = clock()
        let sun = Ephemeris.sun(at: now)
        let (moonEq, _) = Ephemeris.moon(at: now)
        let separation = Ephemeris.separationDeg(sun, moonEq)
        // Only while the Sun is up (amendment 7): a crescent in twilight is fine.
        if let limit = sunLimit(at: now), separation < limit {
            throw MosaicError(
                description: String(
                    format: "The Moon is %.0f° from the Sun, which is up: too close (at least %.0f°).",
                    separation, limit))
        }
        let moon = Ephemeris.moon(at: now, from: settings.site)
        guard moon.horizontal.altDeg > 5 else {
            throw MosaicError(description: "The Moon is below 5° from here now.")
        }
        // A read made since the press: unarmed, reads come every 2 s, and
        // the keys may have moved the mount just before it.
        let pressed = Date()
        var read: [Double]?
        for _ in 0..<40 {
            let st = try mount.status()
            if let p = st.positionsDeg, let age = st.positionsAgeMs,
                Double(age) / 1000 < Date().timeIntervalSince(pressed)
            {
                read = p
                break
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        guard let p = read else {
            throw MosaicError(description: "No position read from the mount: is it answering?")
        }
        try mount.setAltitudeReference(moon.horizontal.altDeg)
        markOnMoon(p, at: now)
        here = Here(time: now, azimuthDeg: p[0], altitudeDeg: p[1], moon: moon)
        centreFit = nil
        litSky = []
        let later = Ephemeris.moon(at: now.addingTimeInterval(60), from: settings.site).horizontal
        approach = (
            wrap180(later.azDeg - moon.horizontal.azDeg) >= 0 ? .positive : .negative,
            later.altDeg >= moon.horizontal.altDeg ? .positive : .negative
        )
        onEvent(
            .message(
                String(
                    format:
                        "Here: Moon at azimuth %.2f°, altitude %.2f°, %.1f′ across; %.0f° from the Sun.",
                    moon.horizontal.azDeg, moon.horizontal.altDeg, moon.diameterDeg * 60,
                    separation)))
        let phase = Ephemeris.phase(at: clock(), from: settings.site)
        onEvent(
            .message(
                String(
                    format:
                        "Phase: %.0f%% lit (phase angle %.0f°); bright limb %.0f° from straight up, clockwise as seen; the terminator crosses %.2f radii from the centre on the dark side.",
                    phase.illuminatedFraction * 100, phase.phaseAngleDeg,
                    phase.brightLimbFromZenithDeg, cos(phase.phaseAngleDeg * .pi / 180))))
    }

    /// The mount's axis angles that put `sky` (relative to the Moon's
    /// centre) in the middle of the frame at `time`.
    public func target(_ sky: SkyOffset, at time: Date) throws -> (az: Double, alt: Double) {
        guard let here else {
            throw MosaicError(description: "Centre the Moon and press Here first.")
        }
        let moon = Ephemeris.moon(at: time, from: settings.site).horizontal
        // The measured drift since Here, too.
        let (b, b0) = (drift.bias(at: time), drift.bias(at: here.time))
        let dAz = wrap180(moon.azDeg - here.moon.horizontal.azDeg) + b.az - b0.az
        let dAlt = moon.altDeg - here.moon.horizontal.altDeg + b.alt - b0.alt
        let offset = MosaicPlanner.axes(for: sky, altitudeDeg: moon.altDeg)
        return (
            Ephemeris.normalize(here.azimuthDeg + dAz + offset.azDeg),
            here.altitudeDeg + dAlt
                + offset.altDeg
        )
    }

    // MARK: Calibration

    /// Learns how the camera sees the sky (ADR 0022 amendment 6): the scale,
    /// the camera's turn and any mirroring, as the 2×2 map from sky offsets
    /// to image pixels. Three measurements, each starting from the Moon held
    /// at the aim, so nothing wanders out of view:
    /// 1. **Drift:** tracking pauses for `driftSeconds` and the Moon drifts
    ///    across the frame. Its motion is known exactly from the ephemeris,
    ///    so the image's motion gives the scale and the turn with no focal
    ///    length needed (Barlows, no diagonal, any camera). Frames a second
    ///    apart move ~50 px each, far from the zero shift where the sensor's
    ///    fixed pattern sits, which is excluded.
    /// 2. **An azimuth move** and 3. **an altitude move**, each from the
    ///    re-centred Moon: the second direction, which settles mirroring.
    /// The map is fitted to all three; each must agree with it within 15%
    /// or the attempt repeats (up to 3). The scale is logged against the
    /// focal-length estimate, which is only a check.
    public func calibrate() async throws {
        guard here != nil else { throw MosaicError(description: "Press Here first.") }
        try camera.configure(exposureUs: settings.exposureUs, gain: settings.gain)
        try camera.start()
        defer { camera.stop() }
        let guess = 206.265 * camera.info.pixelSizeUm / settings.focalLengthMm
        let short = Double(min(camera.info.width, camera.info.height))
        let move = settings.calibrationFraction * short * guess
        // Re-centre: a goto to where the ephemeris puts the aim, then track.
        func centre() async throws {
            try await armForStep()
            try await goToSky(aimOffset)
            endStep()
            try await track(aimOffset, correct: false)
        }
        var why = ""
        for attempt in 1...3 {
            let stamp = Self.fileStamp(clock())
            // 1. Drift.
            try await centre()
            try mount.stopTracking()
            try await Task.sleep(for: .milliseconds(500))
            let still0 = try await freshPosition()
            var drift: [(Frame, Date)] = []
            let driftStart = Date()
            let step = settings.driftSeconds / Double(settings.driftFrames)
            for n in 0...settings.driftFrames {
                // On a schedule, so the steps stay even however long a frame takes.
                let wait = driftStart.addingTimeInterval(Double(n) * step).timeIntervalSinceNow
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                let f = try await grabFrame()
                drift.append((f, clock().addingTimeInterval(f.time.timeIntervalSinceNow)))
            }
            keep(drift.enumerated().map { ("\(stamp)-a\(attempt)-drift\(String(format: "%02d", $0.offset))", $0.element.0) }, in: "calibration")
            var driftSky = SkyOffset(x: 0, y: 0)
            var driftPx = PixelOffset(x: 0, y: 0)
            var driftPairs = 0
            var driftRecords: [[String: Any]] = []
            for (a, b) in zip(drift, drift.dropFirst()) {
                let sky = relativeMove(from: (a.1, still0), to: (b.1, still0))
                let expected = hypot(sky.x, sky.y) / guess
                let r = Registration.shift(from: a.0, to: b.0, minShift: max(6, 0.25 * expected))
                let ok = r.peak > 0.05
                driftRecords.append([
                    "sky": [sky.x, sky.y], "shift": [r.dx, r.dy, r.peak], "used": ok,
                    "dt": b.1.timeIntervalSince(a.1),
                ])
                if ok {
                    driftSky = SkyOffset(x: driftSky.x + sky.x, y: driftSky.y + sky.y)
                    driftPx = PixelOffset(x: driftPx.x + r.dx, y: driftPx.y + r.dy)
                    driftPairs += 1
                }
            }
            // 2 and 3. A move along each axis, each from the held centre, made
            // by tracking a little faster on that axis for a few seconds: the
            // Moon stays put apart from the commanded offset, with no goto, no
            // settle and no drift between the two frames.
            func measure(_ by: SkyOffset, _ name: String) async throws -> (SkyOffset, (dx: Double, dy: Double, peak: Double)) {
                try await centre()
                let (f0, t0, p0) = try await trackedFrame()
                let seconds = settings.calibrationMoveSeconds
                let now = clock()
                let a = try target(aimOffset, at: now.addingTimeInterval(-15))
                let b = try target(aimOffset, at: now.addingTimeInterval(15))
                let alt = here?.moon.horizontal.altDeg ?? 45
                let extra = MosaicPlanner.axes(for: SkyOffset(x: by.x / seconds, y: by.y / seconds), altitudeDeg: alt)
                try mount.track(
                    azDegS: wrap180(b.az - a.az) / 30 + extra.azDeg,
                    altDegS: (b.alt - a.alt) / 30 + extra.altDeg)
                try await Task.sleep(for: .seconds(seconds))
                try await track(aimOffset, correct: false)
                let (f1, t1, p1) = try await trackedFrame()
                keep([("\(stamp)-a\(attempt)-\(name)-0", f0), ("\(stamp)-a\(attempt)-\(name)-1", f1)], in: "calibration")
                let sky = relativeMove(from: (t0, p0), to: (t1, p1))
                let expected = hypot(sky.x, sky.y) / guess
                return (sky, Registration.shift(from: f0, to: f1, minShift: max(6, 0.25 * expected)))
            }
            let (azSky, azShift) = try await measure(SkyOffset(x: move, y: 0), "az")
            let (altSky, altShift) = try await measure(SkyOffset(x: 0, y: move), "alt")
            // Fit image = M · sky to the three, least squares.
            var pairs: [(SkyOffset, PixelOffset)] = []
            if driftPairs >= 2 { pairs.append((driftSky, driftPx)) }
            if azShift.peak > 0.05 { pairs.append((azSky, PixelOffset(x: azShift.dx, y: azShift.dy))) }
            if altShift.peak > 0.05 { pairs.append((altSky, PixelOffset(x: altShift.dx, y: altShift.dy))) }
            let fit = Self.fitMap(pairs)
            let residuals = fit.map { m in
                pairs.map { (s, p) -> Double in
                    let q = m.image(for: s)
                    return hypot(q.x - p.x, q.y - p.y) / max(1, hypot(p.x, p.y))
                }
            } ?? []
            let driftScale = hypot(driftPx.x, driftPx.y) > 0
                ? hypot(driftSky.x, driftSky.y) / hypot(driftPx.x, driftPx.y) : 0
            why = String(
                format: "drift %d pairs, %.0f″ → %.0f px (%.3f″/px); az (%.0f″, %.0f″) → (%.0f, %.0f) px, match %.2f; alt (%.0f″, %.0f″) → (%.0f, %.0f) px, match %.2f; residuals %@",
                driftPairs, hypot(driftSky.x, driftSky.y), hypot(driftPx.x, driftPx.y), driftScale,
                azSky.x, azSky.y, azShift.dx, azShift.dy, azShift.peak,
                altSky.x, altSky.y, altShift.dx, altShift.dy, altShift.peak,
                residuals.map { String(format: "%.0f%%", $0 * 100) }.joined(separator: "/"))
            note(
                "calibration",
                [
                    "time": stamp, "attempt": attempt, "method": "drift+moves",
                    "guessArcsecPerPixel": guess, "moveArcsec": move,
                    "drift": driftRecords, "driftScale": driftScale,
                    "az": ["sky": [azSky.x, azSky.y], "shift": [azShift.dx, azShift.dy, azShift.peak]],
                    "alt": ["sky": [altSky.x, altSky.y], "shift": [altShift.dx, altShift.dy, altShift.peak]],
                    "fit": fit.map { ["a": $0.a, "b": $0.b, "c": $0.c, "d": $0.d,
                                      "arcsecPerPixel": $0.arcsecPerPixel, "rotationDeg": $0.rotationDeg] } ?? [:],
                    "residuals": residuals,
                    "exposureUs": settings.exposureUs, "gain": settings.gain,
                ])
            if let m = fit, pairs.count == 3, residuals.allSatisfy({ $0 <= 0.15 }) {
                calibration = m
                try await centre()
                onEvent(.message("Calibration: \(why)."))
                let vsGuess = m.arcsecPerPixel / guess - 1
                onEvent(
                    .message(
                        String(
                            format: "Calibrated: %.3f″ per pixel (%+.0f%% against %.3f from the %.0f mm focal length), camera turned %.1f°, image %@.",
                            m.arcsecPerPixel, vsGuess * 100, guess, settings.focalLengthMm, m.rotationDeg,
                            m.mirrored ? "mirrored" : "not mirrored")))
                if abs(vsGuess) > 0.25 {
                    onEvent(.message("The scale differs from the focal length's by more than 25%: a Barlow or reducer? If not, check the focal length in Settings."))
                }
                return
            }
            onEvent(.message("Calibration attempt \(attempt) of 3 didn't agree (\(why)); trying again."))
        }
        try? await centre()
        throw MosaicError(
            description: "Calibration failed 3 times (\(why)). Put the limb or the terminator in view and try again.")
    }

    /// The least-squares map image = M · sky through the origin.
    static func fitMap(_ pairs: [(SkyOffset, PixelOffset)]) -> CameraCalibration? {
        guard pairs.count >= 2 else { return nil }
        // M = (Σ p sᵀ)(Σ s sᵀ)⁻¹
        var (sxx, sxy, syy) = (0.0, 0.0, 0.0)
        var (pxsx, pxsy, pysx, pysy) = (0.0, 0.0, 0.0, 0.0)
        for (s, p) in pairs {
            sxx += s.x * s.x; sxy += s.x * s.y; syy += s.y * s.y
            pxsx += p.x * s.x; pxsy += p.x * s.y; pysx += p.y * s.x; pysy += p.y * s.y
        }
        let det = sxx * syy - sxy * sxy
        guard abs(det) > 1e-6 else { return nil }
        let (i11, i12, i22) = (syy / det, -sxy / det, sxx / det)
        return CameraCalibration(
            a: pxsx * i11 + pxsy * i12, b: pxsx * i12 + pxsy * i22,
            c: pysx * i11 + pysy * i12, d: pysx * i12 + pysy * i22)
    }

    /// The change in pointing relative to the Moon between two moments, from
    /// the mount's own positions and the Moon's computed motion.
    public func relativeMove(from a: (Date, [Double]), to b: (Date, [Double])) -> SkyOffset {
        let ma = Ephemeris.moon(at: a.0, from: settings.site).horizontal
        let mb = Ephemeris.moon(at: b.0, from: settings.site).horizontal
        let (ba, bb) = (drift.bias(at: a.0), drift.bias(at: b.0))
        let dAz = wrap180(b.1[0] - a.1[0]) - wrap180(mb.azDeg - ma.azDeg) - (bb.az - ba.az)
        // Wrapped: the altitude encoder can read near 360 (2026-11-20, the
        // test runner: survey frames crossing 0 were placed 360° away).
        let dAlt = wrap180(b.1[1] - a.1[1]) - (mb.altDeg - ma.altDeg) - (bb.alt - ba.alt)
        return SkyOffset(x: dAz * cos(mb.altDeg * .pi / 180) * 3600, y: dAlt * 3600)
    }

    // MARK: Search (ADR 0022)

    /// What a search found.
    public struct SearchOutcome: Sendable {
        /// A bright-enough target came into view.
        public let found: Bool
        /// The mount's position (az, alt degrees) at the found stop, or the
        /// last stop otherwise.
        public let atAzAltDeg: [Double]?
        /// The blob that satisfied `found` (after converging, the final one).
        public let blob: Blob.Found?
        /// Stops visited (gotos issued).
        public let stops: Int
        /// Converging (`Converge`): whether it ended with the frame on the
        /// lit disk, and the gotos it took (each a bounded step).
        public var converged: Bool = false
        public var convergeSteps: Int = 0
    }

    /// Converging onto the disk after the first sighting (track 2, 2c). The
    /// first frame that passes `found` is often only the Moon's glow or a
    /// sliver of limb along one edge; stopping there leaves Here — and the
    /// plan centred on it — off the disk. Converging re-centres on the bright
    /// region's centroid (at a sighting it sits at the frame's edge, towards
    /// the Moon) in bounded steps until the frame is on the lit disk.
    public struct Converge: Sendable {
        /// "Lit" here means above this fraction of the frame's peak: low
        /// enough that maria count against a bright crater (at 30% they
        /// don't, and a frame wholly on the disk reads half lit), high above
        /// the black sky.
        public var litThresholdFraction: Double = 0.15
        /// The frame counts as on the disk at this lit fraction…
        public var onDiskFraction: Double = 0.8
        /// …or at this lower fraction with the lit region's centroid within
        /// `centredFraction` of the frame's short side from the centre.
        public var centredOnDiskFraction: Double = 0.5
        public var centredFraction: Double = 0.1
        /// At most this many steps, each at most `maxStepFrames` of the
        /// frame's short side, and never further than `maxTravelDeg` (sky)
        /// from the sighting.
        public var maxSteps: Int = 12
        public var maxStepFrames: Double = 1.0
        /// Each step moves at least this much of the short side. Near the
        /// limb the lit centroid sits close to the centre, so a step to it
        /// alone was too small to gain anything (2026-11-19: stuck at 62%).
        public var minStepFrames: Double = 0.25
        public var maxTravelDeg: Double = 1.0

        public init() {}
    }

    /// Walks an expanding spiral from the current position (ADR 0022), a frame
    /// at each stop, asking `found` whether the target is in view. Attended and
    /// minimal: each stop is one self-terminating goto, so there is no
    /// latched-runaway path. Ends at the first found stop, when `cancelled` is
    /// raised (the operator's "I see it"), or at the pattern's end. `found`
    /// gets each stop's brightest blob, or nil.
    @discardableResult
    public func searchSpiral(
        stepDeg: Double, reachDeg: Double, referenceAltitudeDeg: Double? = nil,
        converge: Converge? = nil,
        found: @escaping @Sendable (Blob.Found?) -> Bool,
        cancelled: @escaping @Sendable () -> Bool = { false },
        sighted: @escaping @Sendable () -> Bool = { false }
    ) async throws -> SearchOutcome {
        let spiral = SpiralSearch(stepDeg: stepDeg, reachDeg: reachDeg)
        return try await walk(
            spiral.steps.map { ($0.azDeg, $0.altDeg) }, referenceAltitudeDeg, converge, found,
            cancelled, sighted)
    }

    /// Walks a serpentine raster out from the current position (ADR 0022):
    /// the current row first, then rows alternately above and below, as
    /// capture stops `captureStepDeg` apart along each row. (A continuous row
    /// sweep is a later optimisation; these stops drive and test the same
    /// coverage.) Otherwise like `searchSpiral`.
    @discardableResult
    public func searchRaster(
        halfWidthDeg: Double, halfHeightDeg: Double, rowSpacingDeg: Double, captureStepDeg: Double,
        referenceAltitudeDeg: Double? = nil,
        converge: Converge? = nil,
        found: @escaping @Sendable (Blob.Found?) -> Bool,
        cancelled: @escaping @Sendable () -> Bool = { false },
        sighted: @escaping @Sendable () -> Bool = { false }
    ) async throws -> SearchOutcome {
        precondition(captureStepDeg > 0, "captureStepDeg must be positive")
        let raster = RasterSearch(
            halfWidthDeg: halfWidthDeg, halfHeightDeg: halfHeightDeg, rowSpacingDeg: rowSpacingDeg)
        var offsets: [(Double, Double)] = []
        func seen(_ o: (Double, Double)) -> Bool {
            offsets.contains { abs($0.0 - o.0) < 1e-9 && abs($0.1 - o.1) < 1e-9 }
        }
        for row in raster.rows {
            let span = row.toAzDeg - row.fromAzDeg
            let n = max(1, Int((abs(span) / captureStepDeg).rounded(.up)))
            for k in 0...n {
                // A row starts where the last ended, and the start's second
                // half-row starts at the start: shoot each place once.
                let o = (row.fromAzDeg + span * Double(k) / Double(n), row.altDeg)
                if !seen(o) { offsets.append(o) }
            }
        }
        return try await walk(offsets, referenceAltitudeDeg, converge, found, cancelled, sighted)
    }

    /// Shared drive: arm, open the camera, goto each offset (from the start)
    /// in turn, and check the frame's brightest blob; then, with `converge`,
    /// step onto the disk.
    private func walk(
        _ offsets: [(Double, Double)],
        _ referenceAltitudeDeg: Double?,
        _ converge: Converge?,
        _ found: @escaping @Sendable (Blob.Found?) -> Bool,
        _ cancelled: @escaping @Sendable () -> Bool,
        _ sighted: @escaping @Sendable () -> Bool = { false }
    ) async throws -> SearchOutcome {
        // The controller won't arm without a true altitude. A search runs
        // before Here, so tie the encoder to the sky from the rough aim (the
        // Moon's computed altitude, or a terrestrial target's) when nothing
        // has set it yet.
        if let referenceAltitudeDeg, try mount.status().altitudeDeg == nil {
            try mount.setAltitudeReference(referenceAltitudeDeg)
            onEvent(
                .message(
                    String(
                        format: "Search: altitude reference set to %.1f° for the envelope.",
                        referenceAltitudeDeg)))
        }
        try await armForStep()
        defer { endStep() }
        try camera.configure(exposureUs: settings.exposureUs, gain: settings.gain)
        try camera.start()
        defer { camera.stop() }
        let start = try await freshPosition()
        var stops = 0
        var history: [SearchStop] = []
        let searchStamp = Self.fileStamp(clock())
        let pattern = offsets.map { [$0.0, $0.1] }
        // With the Moon: the pattern rides on its motion since the start, so
        // a rising Moon doesn't climb through the rows.
        let searchStart = clock()
        let moonStart = modelMoon(at: searchStart)
        func drift(_ t: Date) -> (Double, Double) {
            guard searchFollowsMoon else { return (0, 0) }
            let m = modelMoon(at: t)
            return (wrap180(m.az - moonStart.az), m.alt - moonStart.alt)
        }
        let field = [
            Double(camera.info.width) * scaleGuess / 3600, Double(camera.info.height) * scaleGuess / 3600,
        ]
        var visited: [[Double]] = []
        var brightness: [Double] = []
        func progress(_ finished: Bool = false) {
            onEvent(
                .search(
                    SearchProgress(
                        pattern: pattern, visited: visited, brightness: brightness, fieldDeg: field,
                        altitudeDeg: Self.moonAxes(at: searchStart, settings.site).alt, start: start, startTime: searchStart,
                        followsMoon: searchFollowsMoon, finished: finished)))
        }
        progress()
        defer { progress(true) }
        for (dAz, dAlt) in offsets {
            if cancelled() { break }
            if sighted() {
                return try await backtrack(history, stops: stops, converge, cancelled)
            }
            // A search move is lean: a straight goto (no anti-backlash
            // overshoot — the search doesn't need backlash precision) and no
            // settle wait. A few-ms exposure freezes any residual motion, so
            // the brightness read is good the instant the move ends. This is
            // what keeps a 40-stop search to seconds, not minutes.
            let d = drift(clock().addingTimeInterval(0.5))
            try await searchGoTo(az: start[0] + dAz + d.0, alt: start[1] + dAlt + d.1)
            stops += 1
            let pos = try await freshPosition()
            let frame = try await grabFrame()
            // Acquisition detects a bright region against dark sky, so count
            // the whole lit target (a low fraction of its peak), not just its
            // brightest parts: brightFraction then reads as "how much of the
            // frame is lit".
            let blob = Blob.find(frame, thresholdFraction: 0.3)
            history.append(SearchStop(position: pos, blob: blob))
            let dNow = drift(clock())
            visited.append([wrap180(pos[0] - start[0]) - dNow.0, pos[1] - start[1] - dNow.1])
            brightness.append(blob.map { Double($0.peak) / 255 * min(1, $0.brightFraction * 3) } ?? 0)
            progress()
            keep([("\(searchStamp)-stop\(String(format: "%03d", stops))", frame)], in: "search")
            note(
                "search",
                [
                    "time": searchStamp, "stop": stops, "offset": [dAz, dAlt], "position": pos,
                    "peak": blob?.peak ?? 0, "brightFraction": blob?.brightFraction ?? 0,
                    "centroidOffset": blob.map { [$0.offsetFromCentre.x, $0.offsetFromCentre.y] } ?? [],
                    "found": found(blob),
                ])
            if found(blob), let blob {
                onEvent(.message("Search: target in view after \(stops) stops."))
                guard let converge else {
                    return SearchOutcome(found: true, atAzAltDeg: pos, blob: blob, stops: stops)
                }
                var outcome = try await convergeOnDisk(from: blob, converge, cancelled)
                outcome = SearchOutcome(
                    found: true, atAzAltDeg: outcome.atAzAltDeg ?? pos, blob: outcome.blob,
                    stops: stops, converged: outcome.converged,
                    convergeSteps: outcome.convergeSteps)
                return outcome
            }
        }
        if sighted() { return try await backtrack(history, stops: stops, converge, cancelled) }
        return SearchOutcome(
            found: false, atAzAltDeg: try? await freshPosition(), blob: nil, stops: stops)
    }

    /// One search stop: where the mount was and what the frame showed.
    struct SearchStop {
        let position: [Double]
        let blob: Blob.Found?
        /// How much bright target the frame held: peak × lit fraction.
        var score: Double { blob.map { Double($0.peak) * $0.brightFraction } ?? 0 }
    }

    /// The operator pressed "I see it" (2026-11-19). By the time the search
    /// notices, the mount has gone on to the next stop and the target can be
    /// out of view, so go back: to the best of the last few stops, then, if
    /// that frame holds less than the best seen, a fine scan back along the
    /// path between them. Then step onto the disk as an automatic find would.
    private func backtrack(
        _ history: [SearchStop], stops: Int, _ converge: Converge?,
        _ cancelled: @escaping @Sendable () -> Bool
    ) async throws -> SearchOutcome {
        let recent = Array(history.suffix(4))
        guard let best = recent.max(by: { $0.score < $1.score }), best.score > 0 else {
            onEvent(.message("I see it: no bright target in the last frames; staying here."))
            return SearchOutcome(
                found: false, atAzAltDeg: try? await freshPosition(), blob: nil, stops: stops)
        }
        onEvent(.message("I see it: going back to where the target was."))
        try await searchGoTo(az: best.position[0], alt: best.position[1])
        var here = SearchStop(position: try await freshPosition(), blob: Blob.find(try await grabFrame(), thresholdFraction: 0.3))
        if here.score < 0.7 * best.score, recent.count >= 2 {
            // Fine scan: three points between each pair of the recent stops,
            // newest first (back the way the mount came).
            var candidates: [SearchStop] = [here]
            for (a, b) in zip(recent.dropFirst().reversed(), recent.dropLast().reversed()) {
                for k in 1...3 {
                    if cancelled() { break }
                    let f = Double(k) / 4
                    let az = a.position[0] + wrap180(b.position[0] - a.position[0]) * f
                    let alt = a.position[1] + (b.position[1] - a.position[1]) * f
                    try await searchGoTo(az: az, alt: alt)
                    candidates.append(
                        SearchStop(
                            position: try await freshPosition(),
                            blob: Blob.find(try await grabFrame(), thresholdFraction: 0.3)))
                }
            }
            if let top = candidates.max(by: { $0.score < $1.score }) {
                try await searchGoTo(az: top.position[0], alt: top.position[1])
                here = SearchStop(position: try await freshPosition(), blob: Blob.find(try await grabFrame(), thresholdFraction: 0.3))
            }
        }
        guard let blob = here.blob else {
            return SearchOutcome(found: false, atAzAltDeg: here.position, blob: nil, stops: stops)
        }
        guard let converge else {
            return SearchOutcome(found: true, atAzAltDeg: here.position, blob: blob, stops: stops)
        }
        let outcome = try await convergeOnDisk(from: blob, converge, cancelled)
        return SearchOutcome(
            found: true, atAzAltDeg: outcome.atAzAltDeg ?? here.position, blob: outcome.blob,
            stops: stops, converged: outcome.converged, convergeSteps: outcome.convergeSteps)
    }

    /// Steps from a sighting onto the lit disk (`Converge`). Each step is one
    /// bounded, self-terminating search goto that moves the lit region's
    /// centroid to the frame's centre. Before a calibration the image's
    /// orientation is a guess that a star diagonal mirrors, so a step that
    /// loses ground (less of the frame lit, the centroid no nearer the
    /// centre) is undone and the next orientation tried: as guessed, mirrored
    /// left-right, mirrored top-bottom, turned 180°. The one that works is
    /// kept for later steps and for recentre. Runs inside `walk`'s armed step.
    func convergeOnDisk(
        from sighting: Blob.Found, _ c: Converge,
        _ cancelled: @escaping @Sendable () -> Bool
    ) async throws -> SearchOutcome {
        let (w, h) = (Double(camera.info.width), Double(camera.info.height))
        let short = min(w, h)
        let maxStepPx = c.maxStepFrames * short
        let minStepPx = c.minStepFrames * short
        func distance(_ b: Blob.Found) -> Double { hypot(b.offsetFromCentre.x, b.offsetFromCentre.y) }
        func onDisk(_ b: Blob.Found) -> Bool {
            b.brightFraction >= c.onDiskFraction
                || (b.brightFraction >= c.centredOnDiskFraction && distance(b) <= c.centredFraction * short)
        }
        let origin = try await freshPosition()
        let alt = { [mount] (p: [Double]) in (try? mount.status())?.altitudeDeg ?? p[1] }
        let lit = { (f: Frame) in Blob.find(f, thresholdFraction: c.litThresholdFraction) }
        var blob = lit(try await grabFrame()) ?? sighting
        var steps = 0
        var orientation = calibration == nil ? searchOrientation : .asGuessed
        var failures = 0
        // A calibration fixes the orientation, so trying the flips is
        // pointless: give up after two steps that lose ground.
        let maxFailures = calibration == nil ? SearchOrientation.allCases.count : 2
        while !onDisk(blob) {
            if cancelled() || steps >= c.maxSteps || failures >= maxFailures {
                break
            }
            // Move the centroid to the centre, at most one step's worth.
            var px = blob.offsetFromCentre
            let len = hypot(px.x, px.y)
            if len > maxStepPx { px = PixelOffset(x: px.x * maxStepPx / len, y: px.y * maxStepPx / len) }
            if len > 0, len < minStepPx { px = PixelOffset(x: px.x * minStepPx / len, y: px.y * minStepPx / len) }
            let before = try await freshPosition()
            let m = MosaicPlanner.axes(for: sky(for: px, orientation), altitudeDeg: alt(before))
            let target = (az: before[0] + m.azDeg, alt: before[1] + m.altDeg)
            let travel = hypot(
                wrap180(target.az - origin[0]) * cos(alt(before) * .pi / 180), target.alt - origin[1])
            if travel > c.maxTravelDeg {
                onEvent(.message(String(format: "Converge: stopped at the %.1f° travel limit.", c.maxTravelDeg)))
                break
            }
            try await searchGoTo(az: target.az, alt: target.alt)
            steps += 1
            let stepFrame = try await grabFrame()
            let next = lit(stepFrame)
            keep([("\(Self.fileStamp(clock()))-converge\(String(format: "%02d", steps))", stepFrame)], in: "search")
            note(
                "search",
                [
                    "kind": "converge", "step": steps, "target": [target.az, target.alt],
                    "brightFraction": next?.brightFraction ?? 0,
                    "centroidOffset": next.map { [$0.offsetFromCentre.x, $0.offsetFromCentre.y] } ?? [],
                ])
            let gained =
                next.map {
                    $0.brightFraction > blob.brightFraction + 0.02
                        || ($0.brightFraction >= blob.brightFraction - 0.02
                            && distance($0) < distance(blob) - 0.05 * short)
                } ?? false
            if gained, let next {
                blob = next
                failures = 0
                continue
            }
            // Lost ground: back to where this step began, next orientation.
            failures += 1
            try await searchGoTo(az: before[0], alt: before[1])
            steps += 1
            if let again = lit(try await grabFrame()) { blob = again }
            if calibration == nil {
                orientation = orientation.next
                onEvent(.message("Converge: that step lost ground; trying the image \(orientation.label)."))
            } else {
                onEvent(.message("Converge: that step lost ground."))
            }
        }
        let converged = onDisk(blob)
        if converged, calibration == nil { searchOrientation = orientation }
        onEvent(
            .message(
                converged
                    ? String(
                        format: "Converge: on the disk after %d steps (%.0f%% of the frame lit)%@.",
                        steps, blob.brightFraction * 100,
                        orientation == .asGuessed || calibration != nil ? "" : "; image \(orientation.label)")
                    : String(
                        format: "Converge: not on the disk after %d steps (%.0f%% lit). Centre it by hand.",
                        steps, blob.brightFraction * 100)))
        return SearchOutcome(
            found: true, atAzAltDeg: try? await freshPosition(), blob: blob, stops: 0,
            converged: converged, convergeSteps: steps)
    }

    /// Sky offset for an image offset: calibrated, or the guess (camera
    /// square to the sky, x right → azimuth, y down → lower altitude) with
    /// `orientation`'s flips applied first.
    private func sky(for px: PixelOffset, _ orientation: SearchOrientation) -> SkyOffset {
        if let calibration { return calibration.sky(for: px) }
        let f = orientation.flips
        let p = PixelOffset(x: f.x * px.x, y: f.y * px.y)
        return SkyOffset(x: p.x * scaleGuess, y: -p.y * scaleGuess)
    }

    /// Slews so the point at `pixelOffset` from the frame's centre comes to
    /// the centre (ADR 0022 click-to-recentre). With a calibration the move is
    /// exact; before one it uses the scale from the focal length with the
    /// camera assumed square to the sky (x right → azimuth, y down → lower
    /// altitude), so the direction is a guess the operator can correct by
    /// clicking again. One self-terminating goto per axis; the altitude
    /// reference must already be set (a search sets it).
    public func recentre(pixelOffset: PixelOffset) async throws {
        let sky = sky(for: pixelOffset, searchOrientation)
        try await armForStep()
        defer { endStep() }
        let pos = try await freshPosition()
        let alt = (try? mount.status())?.altitudeDeg ?? pos[1]
        let m = MosaicPlanner.axes(for: sky, altitudeDeg: alt)
        try await goTo(az: pos[0] + m.azDeg, alt: pos[1] + m.altDeg)
    }

    // MARK: Finding the centre

    /// Surveys a grid of frames around Here at the survey exposure, fits the
    /// Moon's disk, and moves Here to its centre (amendment 1). Every move
    /// is a small goto near the Moon, checked like any other; none goes
    /// further than `surveyReach` Moon radii from Here.
    @discardableResult
    public func findCentre() async throws -> MoonCentre.Fit {
        guard calibration != nil else { throw MosaicError(description: "Orient the camera first.") }
        // The Moon is in view (Orient Camera needed it): tie the encoders to
        // the sky here if nothing has yet (centred by hand, say).
        if here == nil { try await markHere() }
        guard let calibration, let here else { throw MosaicError(description: "Orient the camera first.") }
        let radius = here.moon.diameterDeg / 2 * 3600
        // The tracking's drift first, so everything after it (the probe, the
        // plan, the capture) uses a Moon model that keeps up with the real
        // Moon (2026-11-20, first night: 1–2″/s uncorrected).
        do {
            // Orient Camera measures it too; again only if that was a while ago.
            if let t = drift.measured, clock().timeIntervalSince(t) < 300 {
            } else {
                try await measureDrift()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            onEvent(.message("Tracking drift not measured (\(error)); carrying on without the correction."))
        }
        let fit: MoonCentre.Fit
        var samples: [MoonCentre.Sample] = []
        var method = "survey"
        // The limb probe first: three short lines out across the sunlit
        // limb and a circle through the sharp edges (2026-11-20, first
        // night: the survey's fits, pulled by the glow beside the bright
        // limb, put the centre 256″ off). The survey if the probe fails.
        if let probed = try await probeLimbCentre(radius: radius) {
            fit = probed
            method = "limb"
        } else {
            (fit, samples) = try await surveyCentre(here: here, calibration: calibration, radius: radius)
        }
        // Here moves to the centre: the same moment, the axes shifted.
        let shift = MosaicPlanner.axes(for: fit.centre, altitudeDeg: here.moon.horizontal.altDeg)
        self.here = Here(
            time: here.time, azimuthDeg: Ephemeris.normalize(here.azimuthDeg + shift.azDeg),
            altitudeDeg: here.altitudeDeg + shift.altDeg, moon: here.moon)
        litSky = samples.filter { $0.mean >= fit.levels.lit }.map {
            SkyOffset(x: $0.sky.x - fit.centre.x, y: $0.sky.y - fit.centre.y)
        }
        surveyCells = samples.map {
            (x: ($0.sky.x - fit.centre.x) / radius, y: ($0.sky.y - fit.centre.y) / radius, lit: $0.mean >= fit.levels.lit)
        }
        centreFit = fit
        plan = nil
        checkRotation()
        // The aim was relative to the old Here; start again from the centre.
        aimOffset = SkyOffset(x: 0, y: 0)
        // The altitude reference was set off-centre at Here: set it again,
        // from where the mount points now against where the centre is.
        let now = clock()
        let pos = try await freshPosition()
        let centreNow = try target(SkyOffset(x: 0, y: 0), at: now)
        let moonNow = Ephemeris.moon(at: now, from: settings.site).horizontal
        try mount.setAltitudeReference(moonNow.altDeg + wrap180(pos[1] - centreNow.alt))
        try await goToSky(SkyOffset(x: 0, y: 0))
        if let p = try? await freshPosition() { markOnMoon(p, at: clock()) }
        centreFixedAt = clock()
        // Tracking on, unarmed (as the survey's own ending used to leave it).
        endStep()
        let rate = moonRate(at: clock())
        try? mount.track(azDegS: rate.az, altDegS: rate.alt)
        onEvent(
            .message(
                String(
                    format:
                        "Centre found %.0f″ from Here (%.0f″, %.0f″) by the %@; %.0f%% %@ agree%@.",
                    hypot(fit.centre.x, fit.centre.y), fit.centre.x, fit.centre.y, method,
                    fit.agreement * 100, method == "limb" ? "of edge points" : "of cells",
                    method == "limb" ? "" : (fit.earthshine ? "; earthshine seen" : "; no earthshine above the sky"))))
        return fit
    }

    /// The survey's centre (amendment 1): frames on a grid around Here, cut
    /// into cells and fitted.
    private func surveyCentre(
        here: Here, calibration: CameraCalibration, radius: Double
    ) async throws -> (MoonCentre.Fit, [MoonCentre.Sample]) {
        let reach = settings.surveyReach * radius
        // Frames 1.4 frames apart over a circle of `reach`: the fit needs
        // cells across the limb, not every part of the sky.
        let grid = MosaicPlanner.plan(
            moonDiameterDeg: 2 * reach / 3600, calibration: calibration,
            frameWidth: camera.info.width, frameHeight: camera.info.height,
            overlap: -settings.surveySpacing + 1, margin: 0)
        let stops = grid.tiles.map(\.pointing).filter {
            hypot($0.x, $0.y) <= reach + Double(max(camera.info.width, camera.info.height))
                * calibration.arcsecPerPixel
        }
        onEvent(.message("Survey: \(stops.count) frames, to \(Int(reach / 60))′ from Here."))
        // Hops between frames are rate moves on top of tracking (both axes
        // together, 1.5°/s), not the firmware's slow gotos one axis at a
        // time with a settle each: 2026-11-20, the survey took minutes.
        if (try? mount.status().state) == "Armed" { endStep() }
        defer {
            let r = moonRate(at: clock())
            try? mount.track(azDegS: r.az, altDegS: r.alt)
        }
        // By day the survey's long exposure (meant to show earthshine on a
        // dark sky) is all sky, saturated, with no edge to find (2026-11-20,
        // simulator): the video's exposure instead, the Moon above the sky.
        let daytime = sunHorizontal(at: clock()).altDeg > SunGuard.upAltitudeDeg
        let (surveyExposure, surveyGain) =
            daytime ? (settings.exposureUs, settings.gain) : (settings.surveyExposureUs, settings.surveyGain)
        if daytime {
            onEvent(.message(String(format: "Survey: daytime, at the video's %.1f ms and gain %d.", Double(settings.exposureUs) / 1000, settings.gain)))
        }
        try camera.configure(exposureUs: surveyExposure, gain: surveyGain)
        try camera.start()
        defer {
            camera.stop()
            try? camera.configure(exposureUs: settings.exposureUs, gain: settings.gain)
        }
        var samples: [MoonCentre.Sample] = []
        let origin = (here.time, [here.azimuthDeg, here.altitudeDeg])
        let surveyStamp = Self.fileStamp(clock())
        for (i, stop) in stops.enumerated() {
            // One goto, no touch-ups: where it really pointed is read below.
            onEvent(.detail("Survey frame \(i + 1) of \(stops.count)"))
            // No corrections: where it really pointed is read below, so
            // a tenth of a degree off costs nothing (corrections made the
            // survey 4 minutes on the first night, 2026-11-20).
            try await rateMove(to: try target(stop, at: clock()), speedDegS: 1.5, toleranceDeg: 0.1)
            let moved = Date()
            // Let the tube stop ringing, then a read made since the move
            // ended, then a frame, and where it was: the read carried to the
            // frame's moment at the tracking rates.
            try await Task.sleep(for: .milliseconds(Int(max(300, settings.settleSeconds * 700))))
            let read = try await readAfter(moved)
            let frame = try await grabFrame()
            let r = (try? mount.status().tracking) ?? nil ?? [0, 0]
            let ahead = frame.time.timeIntervalSince(read.wall)
            let p = [read.p[0] + r[0] * ahead, read.p[1] + r[1] * ahead]
            let t = clock().addingTimeInterval(frame.time.timeIntervalSinceNow)
            // Where the camera really pointed, from the mount's own position.
            let pointing = relativeMove(from: origin, to: (t, p))
            keep([("\(surveyStamp)-\(String(format: "%02d", i))", frame)], in: "survey")
            note(
                "survey",
                [
                    "time": surveyStamp, "stop": i, "planned": [stop.x, stop.y],
                    "pointing": [pointing.x, pointing.y], "position": p,
                    // Simulating: where the camera really pointed (from the Moon's centre).
                    "simTruth": (camera as? SimCamera)?.history.last.map { [$0.x, $0.y] } ?? NSNull(),
                    "exposureUs": surveyExposure, "gain": surveyGain,
                ])
            samples += MoonCentre.samples(
                frame, pointing: pointing, calibration: calibration,
                cellPixels: Int((25 / calibration.arcsecPerPixel).rounded()))
            if (i + 1) % 10 == 0 { onEvent(.message("Survey: \(i + 1) of \(stops.count).")) }
        }
        // The sunlit shape from the ephemeris first (glow-proof); the plain
        // disk if that doesn't fit (the phase not as predicted: a test
        // target, or the camera's turn wrong).
        var fitted = MoonCentre.fit(
            samples, radiusArcsec: radius, searchArcsec: 1.1 * radius,
            phase: Ephemeris.phase(at: clock(), from: settings.site))
        if (fitted?.agreement ?? 0) < 0.85,
            let disk = MoonCentre.fit(samples, radiusArcsec: radius, searchArcsec: 1.1 * radius),
            disk.agreement > (fitted?.agreement ?? 0)
        {
            onEvent(
                .message(
                    String(
                        format: "Survey: the sunlit shape fitted %.0f%% of cells, the plain disk %.0f%%; using the disk.",
                        (fitted?.agreement ?? 0) * 100, disk.agreement * 100)))
            fitted = disk
        }
        // The analysis, for later review: every cell and the fit's answer.
        let phaseNow = Ephemeris.phase(at: clock(), from: settings.site)
        var summary: [String: Any] = [
            "time": surveyStamp, "kind": "fit", "radiusArcsec": radius, "cells": samples.count,
            "calibration": [
                "arcsecPerPixel": calibration.arcsecPerPixel, "rotationDeg": calibration.rotationDeg,
            ],
            "phase": [
                "illuminatedFraction": phaseNow.illuminatedFraction,
                "phaseAngleDeg": phaseNow.phaseAngleDeg,
                "brightLimbFromZenithDeg": phaseNow.brightLimbFromZenithDeg,
            ],
        ]
        if let f = fitted {
            summary["centre"] = [f.centre.x, f.centre.y]
            summary["agreement"] = f.agreement
            summary["moonCells"] = f.moonCells
            summary["litCells"] = f.litCells
            summary["skyCells"] = f.skyCells
            summary["earthshine"] = f.earthshine
            summary["levels"] = ["sky": f.levels.sky, "moon": f.levels.moon, "lit": f.levels.lit]
        } else {
            summary["centre"] = NSNull()
        }
        note("survey", summary)
        keepText(
            "survey", "\(surveyStamp)-cells.csv",
            "skyX,skyY,mean\n" + samples.map { String(format: "%.1f,%.1f,%.2f", $0.sky.x, $0.sky.y, $0.mean) }
                .joined(separator: "\n") + "\n")
        onEvent(.detail(nil))
        guard let fit = fitted, fit.agreement > 0.85
        else {
            try await goToSky(SkyOffset(x: 0, y: 0))
            throw MosaicError(
                description:
                    "Couldn't find the Moon's edge in the survey. Is Here on the lit Moon, and the survey exposure right (Settings)?")
        }
        return (fit, samples)
    }

    /// Orient Moon's rotation check (amendment 7): the sunlit shape the
    /// ephemeris predicts is turned through a full circle, and the turn that
    /// best matches the survey's sunlit and dark cells on the disk is the
    /// camera's error. Every covered cell counts, so where the survey
    /// happened to reach doesn't bias it (the lit cells' centroid did:
    /// 2026-11-20, the test runner, 34–69° off with the wider ASI482MC).
    /// Away from full only. Returns the error in degrees.
    @discardableResult
    func checkRotation() -> Double? {
        let phase = Ephemeris.phase(at: clock(), from: settings.site)
        guard phase.phaseAngleDeg > 35 else { return nil }
        let cells = surveyCells.filter {
            let d = hypot($0.x, $0.y)
            return d < 0.97
        }
        guard cells.count >= 20, cells.contains(where: \.lit), cells.contains(where: { !$0.lit }) else { return nil }
        let c = cos(phase.phaseAngleDeg * .pi / 180)
        let base = atan2(phase.brightLimb.x, phase.brightLimb.y)
        func score(_ turnDeg: Double) -> Int {
            let t = base + turnDeg * .pi / 180
            let (lx, ly) = (sin(t), cos(t))
            var n = 0
            for p in cells {
                let a = p.x * lx + p.y * ly
                let b = -p.x * ly + p.y * lx
                let term = -c * max(0, 1 - b * b).squareRoot()
                if abs(a - term) < 0.04 { continue }
                if (a > term) == p.lit { n += 1 }
            }
            return n
        }
        var best = (turn: 0.0, n: -1)
        for turn in stride(from: -180.0, to: 180, by: 2) {
            let n = score(turn)
            if n > best.n || (n == best.n && abs(turn) < abs(best.turn)) { best = (turn, n) }
        }
        let off = abs(best.turn)
        onEvent(
            .message(
                off < 30
                    ? String(format: "Rotation check: the lit side is where the ephemeris puts it (%.0f° off).", off)
                    : String(
                        format:
                            "Rotation check FAILED: the lit side is %.0f° from where the ephemeris puts it. Orient Camera again (mirroring or the turn is wrong).",
                        off)))
        return off
    }

    // MARK: Plan and run

    /// Plans the tiles around Here. Without a centre fit, Here is wherever
    /// the operator (or a search) left the mount, so the grid can sit off
    /// the disk (2026-11-17: ~0.7 Moon radii high). That needs
    /// `allowWithoutCentre`: the app asks the operator first.
    @discardableResult
    public func makePlan(allowWithoutCentre: Bool = false) throws -> MosaicPlan {
        guard let calibration, let here else { throw MosaicError(description: "Orient the camera and the Moon first.") }
        guard centreFit != nil || allowWithoutCentre else {
            throw MosaicError(
                description:
                    "Find centre hasn't succeeded, so the plan would be centred on Here, which may be off the Moon's centre.")
        }
        var plan = MosaicPlanner.plan(
            moonDiameterDeg: here.moon.diameterDeg, calibration: calibration,
            frameWidth: camera.info.width, frameHeight: camera.info.height,
            overlap: settings.overlap, margin: settings.planMargin)
        var dropped = 0
        if let fit = centreFit {
            // Lit or dark from the ephemeris (where the Sun lights the disk),
            // with a margin of a tenth of a frame for error in the centre and
            // the turn. Dark tiles stay in the plan, for the Earthshine pass,
            // only when the survey saw earthshine; otherwise there is nothing
            // in them to capture (2026-11-20: they came out black).
            let phase = Ephemeris.phase(at: clock(), from: settings.site)
            let r = here.moon.diameterDeg / 2 * 3600
            plan = MosaicPlanner.markLit(
                plan, calibration: calibration, phase: phase, radiusArcsec: r)
            // Earthshine never shows in daylight (the dark side is the
            // sky's own brightness, which can pass for it).
            let daylight = sunHorizontal(at: clock()).altDeg > SunGuard.upAltitudeDeg
            let drop: Bool
            switch settings.darkTiles {
            case .auto: drop = !fit.earthshine || daylight
            case .include: drop = false
            case .omit: drop = true
            }
            if drop {
                let before = plan.tiles.count
                plan = MosaicPlanner.withoutDark(plan)
                dropped = before - plan.tiles.count
            }
        }
        self.plan = plan
        states = Dictionary(uniqueKeysWithValues: plan.tiles.map { ($0.id, .pending) })
        stacks = [:]
        let lit = plan.tiles.filter(\.lit).count
        onEvent(
            .message(
                lit == plan.tiles.count
                    ? "Plan: \(plan.tiles.count) tiles\(dropped > 0 ? " (\(dropped) on the dark side left out: no earthshine seen)" : "")."
                    : settings.darkTiles == .include
                        ? "Plan: \(plan.tiles.count) tiles, \(lit) sunlit and \(plan.tiles.count - lit) on the dark side; Start shoots them all."
                        : "Plan: \(plan.tiles.count) tiles, \(lit) sunlit; Start shoots those, and Earthshine the \(plan.tiles.count - lit) on the dark side."))
        return plan
    }

    /// Captures `tiles` (every tile not yet done, lit or dark, by default) into `folder`, one SER
    /// each. `shouldContinue` is checked between tiles (pause, stop).
    public func run(
        tiles: [Int]? = nil, into folder: URL, shouldContinue: @Sendable () -> Bool = { true }
    ) async throws {
        guard let plan else { throw MosaicError(description: "Plan first.") }
        // The centre checked against the limb first if it's a while old
        // (the model drifts: 2026-11-20, a capture 1,300″ off).
        if let t = centreFixedAt, clock().timeIntervalSince(t) > 120 { await limbCheckQuietly() }
        try await armForStep()
        defer { endStep() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try camera.configure(exposureUs: settings.exposureUs, gain: settings.gain)
        let log = SessionLog(folder: folder)
        if loggedPlanIn != folder, let calibration, let here {
            record {
                let sim = camera as? SimCamera ?? (camera as? SharedCamera)?.camera as? SimCamera
                let simulated = mount.opened.simulated || sim != nil
                try log.plan(
                    plan, calibration: calibration, moonDiameterDeg: here.moon.diameterDeg,
                    colorID: SerWriter.colorID(for: camera.info), time: clock(),
                    simulated: simulated,
                    mount: mount.opened.simulated ? "simulated" : (mount.opened.model ?? "real"),
                    camera: camera.info.name, scene: sim?.scene.name)
                if simulated {
                    onEvent(.message("This run is SIMULATED (\(mount.opened.simulated ? "simulated mount" : "real mount"), \(sim != nil ? "simulated camera" : "real camera")); its session.ndjson says so."))
                }
            }
            loggedPlanIn = folder
        }
        // The main pass shoots the sunlit tiles (from the ephemeris, with a
        // margin; on 2026-11-19 the survey's sparse marks left interior
        // tiles near the terminator unshot). The dark ones wait for the
        // Earthshine pass, at its own exposure.
        let ids =
            tiles
            ?? plan.tiles.filter { $0.lit || settings.darkTiles == .include }.map(\.id).filter {
                if case .done = states[$0] { return false } else { return true }
            }
        for id in ids {
            guard shouldContinue() else { break }
            guard let tile = plan.tiles.first(where: { $0.id == id }) else { continue }
            // And again every five minutes of capture.
            if let t = centreFixedAt, clock().timeIntervalSince(t) > 300 { await limbCheckQuietly() }
            do {
                set(id, .moving)
                try await goToSky(tile.pointing)
                // Track during the video so the Moon holds still on the
                // sensor; the next tile's goto stops it.
                do {
                    try await track(tile.pointing, correct: false)
                } catch {
                    onEvent(.message("Tile \(id): couldn't start tracking (\(error)); capturing untracked."))
                }
                set(id, .capturing)
                let r = try await capture(tile, into: folder)
                record {
                    try log.done(
                        id, file: r.file, frames: r.frames, sharpness: r.sharpness, start: r.start,
                        end: r.end, positionDeg: r.position, measured: r.measured)
                }
                set(id, .done(file: r.file, frames: r.frames, sharpness: r.sharpness))
            } catch {
                record { try log.failed(id, reason: "\(error)") }
                set(id, .failed("\(error)"))
                if try mount.status().state == "FaultLatched" { throw error }
            }
        }
    }

    /// A session-log write; a failure is reported but doesn't stop the run.
    private func record(_ write: () throws -> Void) {
        do {
            try write()
        } catch {
            onEvent(.message("Couldn't write the session log: \(error)"))
        }
    }

    private func set(_ id: Int, _ state: TileState) {
        states[id] = state
        onEvent(.tile(id, state))
    }

    private func capture(_ tile: Tile, into folder: URL) async throws -> (
        file: String, frames: Int, sharpness: Double, start: Date, end: Date,
        position: [Double]?, measured: PixelOffset?
    ) {
        try camera.start()
        defer { camera.stop() }
        let name = String(format: "tile-%02d-r%02d-c%02d.ser", tile.id, tile.row, tile.column)
        let writer = try SerWriter(
            url: folder.appendingPathComponent(name), width: camera.info.width,
            height: camera.info.height, colorID: SerWriter.colorID(for: camera.info),
            instrument: camera.info.name, telescope: "Moon mosaic", start: clock())
        var stack = QuickStack(keep: 8)
        saving.begin(.product("tile \(tile.id) video"))
        defer { saving.end() }
        let end = clock().addingTimeInterval(settings.videoSeconds)
        // The first and last frames' times, on the session's clock.
        var first: Date?
        var last = Date()
        while clock() < end {
            guard let frame = try camera.frame(timeoutMs: 500) else { continue }
            last = clock().addingTimeInterval(frame.time.timeIntervalSinceNow)
            if first == nil { first = last }
            try writer.append(frame)
            saving.saved(1, purpose: nil)
            stack.offer(frame)
            await Task.yield()
        }
        let frames = writer.frameCount
        try writer.finish()
        guard frames > 0, let first else {
            throw MosaicError(description: "No frames arrived from the camera.")
        }
        stacks[tile.id] = stack
        // Untracked, the mount holds still through the video, so one read
        // serves, taken against the Moon midway between the first and last
        // frames. Tracked, the mount follows the Moon, so the read is taken
        // at its own time.
        let st = try? mount.status()
        let position = st?.positionsDeg
        var measured: PixelOffset?
        if let position, let here, let calibration {
            let when =
                st?.tracking != nil
                ? clock().addingTimeInterval(-Double(st?.positionsAgeMs ?? 0) / 1000)
                : first.addingTimeInterval(last.timeIntervalSince(first) / 2)
            let sky = relativeMove(
                from: (here.time, [here.azimuthDeg, here.altitudeDeg]), to: (when, position))
            let p = calibration.image(for: sky)
            measured = PixelOffset(x: -p.x, y: -p.y)
        }
        return (name, frames, stack.bestSharpness, first, last, position, measured)
    }

    // MARK: Diagnostics

    static func fileStamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HHmmss"
        return f.string(from: d)
    }

    /// Saves frames as 8-bit PGM under `diagnostics/sub`. Never fails a step.
    func keep(_ frames: [(String, Frame)], in sub: String) {
        guard let diagnostics else { return }
        saving.saved(frames.count, purpose: SavingInfo.purpose(of: sub))
        let dir = diagnostics.appendingPathComponent(sub)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, f) in frames {
                let channels = max(1, f.pixels.count / max(1, f.width * f.height))
                var data = Data("P\(channels == 3 ? 6 : 5)\n\(f.width) \(f.height)\n255\n".utf8)
                data.append(contentsOf: f.pixels.prefix(f.width * f.height * (channels == 3 ? 3 : 1)))
                try data.write(to: dir.appendingPathComponent("\(name).\(channels == 3 ? "ppm" : "pgm")"))
            }
        } catch {
            onEvent(.message("Couldn't save \(sub) frames: \(error.localizedDescription)"))
        }
    }

    /// Writes a text file under `diagnostics/sub`.
    private func keepText(_ sub: String, _ name: String, _ text: String) {
        guard let diagnostics else { return }
        let dir = diagnostics.appendingPathComponent(sub)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: dir.appendingPathComponent(name))
    }

    /// Appends one JSON line to `diagnostics/sub/records.ndjson`.
    func note(_ sub: String, _ record: [String: Any]) {
        guard let diagnostics else { return }
        let dir = diagnostics.appendingPathComponent(sub)
        let url = dir.appendingPathComponent("records.ndjson")
        guard JSONSerialization.isValidJSONObject(record),
            var line = try? JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
        else { return }
        line.append(0x0A)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile()
            h.write(line)
            try? h.close()
        } else {
            try? line.write(to: url)
        }
    }

    // MARK: Moving

    /// One Hold tick (ADR 0022 amendment 5): a goto to the aim only when not
    /// tracking yet or off by more than about 2′, then tracking at the
    /// Moon's rate with a gentle correction toward the aim. Called every
    /// few seconds, so the image stays put instead of jumping.
    public func hold() async throws {
        guard here != nil else { throw MosaicError(description: "Press Here first.") }
        let s = try mount.status()
        let aim = try target(aimOffset, at: clock())
        let error = s.positionsDeg.map {
            hypot(wrap180(aim.az - $0[0]) * cos(aim.alt * .pi / 180), aim.alt - $0[1])
        } ?? .infinity
        if s.tracking == nil || error > 0.033 {
            try await armForStep()
            try await goToSky(aimOffset)
            endStep()
        }
        try await track(aimOffset, correct: true)
    }

    /// Tracks the sky point `sky` (relative to the Moon's centre): both axes
    /// at its computed rate, from the ephemeris over ±15 s. With `correct`,
    /// a little extra (at most 7″/s) closes the gap to it over about 20 s;
    /// without, the rate alone, so a video sees no extra drift.
    public func track(_ sky: SkyOffset, correct: Bool) async throws {
        let now = clock()
        let a = try target(sky, at: now.addingTimeInterval(-15))
        let b = try target(sky, at: now.addingTimeInterval(15))
        var rate = (az: wrap180(b.az - a.az) / 30, alt: (b.alt - a.alt) / 30)
        if correct, let p = try mount.status().positionsDeg {
            let c = try target(sky, at: now)
            let limit = 0.002
            rate.az += max(-limit, min(limit, wrap180(c.az - p[0]) / 20))
            rate.alt += max(-limit, min(limit, wrap180(c.alt - p[1]) / 20))
        }
        try mount.track(azDegS: rate.az, altDegS: rate.alt)
    }

    /// Arms the mount for a step's moves. Arming wants fresh, steady
    /// position reads, so a refusal is retried for a few seconds (the keys
    /// may have just been used).
    func armForStep() async throws {
        let s = try mount.status()
        switch s.state {
        case "Armed": return
        case "FaultLatched":
            try await recoverFromFault(s.lastFault)
            return
        default: break
        }
        var last: Error?
        for _ in 0..<60 {
            do {
                try mount.arm()
                return
            } catch {
                last = error
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw last ?? MosaicError(description: "Couldn't arm the mount.")
    }

    /// Disarms after a step, unless a fault latched it.
    func endStep() {
        if (try? mount.status().state) == "Armed" { try? mount.disarm() }
    }

    /// Aims `sky` (relative to the Moon's centre) for the middle of the
    /// coming video: the gotos, then up to three touch-ups while the error,
    /// against where the Moon will be by then, is over 5% of the frame.
    public func goToSky(_ sky: SkyOffset) async throws {
        // A goto ends with the settle; a passing check starts the video at once.
        let ahead = settings.videoSeconds / 2
        let settle = settings.settleSeconds
        var aim = try target(sky, at: clock().addingTimeInterval(settle + ahead + 2))
        try await goTo(az: aim.az, alt: aim.alt)
        let tolerance = 0.05 * Double(min(camera.info.width, camera.info.height)) * scaleGuess
        for _ in 0..<3 {
            // Judged against the video's middle if it started now; a
            // touch-up aims a second further on, for its own travel.
            let check = try target(sky, at: clock().addingTimeInterval(ahead))
            let p = try await freshPosition()
            let alt = here?.moon.horizontal.altDeg ?? 45
            let error = SkyOffset(
                x: wrap180(check.az - p[0]) * cos(alt * .pi / 180) * 3600,
                y: wrap180(check.alt - p[1]) * 3600)
            if hypot(error.x, error.y) <= tolerance { return }
            aim = try target(sky, at: clock().addingTimeInterval(settle + ahead + 1))
            try await goTo(az: aim.az, alt: aim.alt)
        }
    }

    /// Arcseconds per pixel: calibrated, or from the pixel size and focal length.
    private var scaleGuess: Double {
        calibration?.arcsecPerPixel ?? 206.265 * camera.info.pixelSizeUm / settings.focalLengthMm
    }

    /// Moves by `sky` from where the mount points now.
    func goBy(_ sky: SkyOffset) async throws {
        guard let p = try mount.status().positionsDeg, let here else { return }
        let alt = here.moon.horizontal.altDeg
        let m = MosaicPlanner.axes(for: sky, altitudeDeg: alt)
        try await goTo(az: p[0] + m.azDeg, alt: p[1] + m.altDeg)
    }

    /// Gotos on each axis in turn to these axis angles, always finishing
    /// moving the Moon's way on that axis, so backlash drops out.
    func goTo(az: Double, alt: Double) async throws {
        for (axis, target) in [(MountSession.Axis.azimuth, az), (.altitude, alt)] {
            let way = axis == .azimuth ? approach.az : approach.alt
            let position = try await freshPosition()
            try await moveAxis(axis, to: target, approach: way)
            if ProcessInfo.processInfo.environment["MOSAIC_DEBUG"] != nil {
                let st = try mount.status()
                onEvent(
                    .message(
                        "goto \(axis) to \(target)° from \(position) → \(st.positionsDeg ?? []) (age \(st.positionsAgeMs ?? -1) ms, \(st.lastRecord?.lastStage ?? "?"))"
                    ))
            }
        }
        try await Task.sleep(for: .seconds(settings.settleSeconds))
    }

    /// A search move: straight gotos (no anti-backlash approach overshoot) and
    /// no settle wait. For acquisition only, where the target is a bright blob
    /// and a few-ms exposure freezes the image — not for mosaic capture.
    private func searchGoTo(az: Double, alt: Double) async throws {
        for (axis, target) in [(MountSession.Axis.azimuth, az), (.altitude, alt)] {
            try await moveAxis(axis, to: target, approach: nil)
        }
    }

    /// The mount stopped on a fault during a move.
    struct FaultStop: Error, CustomStringConvertible {
        let fault: MountSession.Fault?
        var description: String { "The mount stopped on a fault: \(fault?.detail ?? "?")" }
    }

    /// How many times one axis move is tried before the step gives up.
    static let moveAttempts = 5

    /// One axis's goto to `target`, retried after a fault (ADR 0022 amendment
    /// 4): in attended operation a fault never ends the step. The fault is
    /// cleared once the hand controller answers again, and the move is
    /// re-planned from a fresh position and sent again.
    func moveAxis(
        _ axis: MountSession.Axis, to target: Double, approach way: MountSession.Direction?
    ) async throws {
        for attempt in 1...Self.moveAttempts {
            let position = try await freshPosition()
            let delta = wrap180(target - position[axis == .azimuth ? 0 : 1])
            if abs(delta) < 0.000_05 { return }
            let index = axis == .azimuth ? 0 : 1
            var end = position
            end[index] = position[index] + delta
            try checkSun(from: position, to: end, what: "the \(axis) goto")
            motion.set(axis: index, from: position[index], to: position[index] + delta)
            defer { motion.clear() }
            do {
                // Tracking (during a video) leaves the mount disarmed: arm
                // again, which also stops the tracking.
                if (try? mount.status().state) != "Armed" { try await armForStep() }
                try await retrying { try self.mount.goto(axis, by: delta, approach: way) }
                try await waitForMotionToEnd()
                lastMoveEnd = Date()
                return
            } catch {
                let s = try? mount.status()
                let latched = error is FaultStop || s?.state == "FaultLatched"
                guard latched, attempt < Self.moveAttempts else { throw error }
                try await recoverFromFault(s?.lastFault ?? (error as? FaultStop)?.fault)
                onEvent(.message("Retrying the \(axis) move (attempt \(attempt + 1) of \(Self.moveAttempts))."))
            }
        }
    }

    /// Clears a latched fault without the operator (ADR 0022 amendment 4):
    /// waits until the hand controller answers and the mount is still, then
    /// resets and re-arms. The operator's own emergency stop is never undone.
    private func recoverFromFault(_ fault: MountSession.Fault?) async throws {
        if fault?.kind == "emergency_stop" || fault?.kind == "process_shutdown" {
            throw MosaicError(description: "Stopped by the operator (\(fault?.kind ?? "")).")
        }
        onEvent(
            .message(
                "Fault \(fault?.kind ?? "?") (\(fault?.detail ?? "?")): clearing it and carrying on once the hand controller answers."))
        let end = Date().addingTimeInterval(90)
        while Date() < end {
            let s = try mount.status()
            for m in s.messages { onEvent(.message(m)) }
            switch s.state {
            case "Armed":
                onEvent(.message("Recovered from the fault."))
                return
            case "FaultLatched":
                try? mount.reset()
            case "Moving", "Stopping":
                break
            default:
                try? mount.arm()
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        throw MosaicError(
            description:
                "The mount didn't recover within 90 s. Unplug the hand controller's USB and the mount's power, plug both back in, and reconnect.")
    }

    /// The latest camera frame, without waiting for the image to settle.
    func grabFrame() async throws -> Frame {
        for _ in 0..<20 {
            if let f = try camera.frame(timeoutMs: 1_000) { return f }
        }
        throw MosaicError(description: "No frames from the camera.")
    }

    /// A position read made after `moment` (wall clock), and when it was
    /// made: a read from before a move ended, carried forward at the
    /// tracking rate, misplaces the end of the move (2026-11-20, the test
    /// runner: survey frames placed up to 200″ off). Up to `limit` seconds;
    /// then the latest read.
    func readAfter(_ moment: Date, limit: Double = 3) async throws -> (wall: Date, p: [Double]) {
        let deadline = Date().addingTimeInterval(limit)
        while true {
            let st = try mount.status()
            if let p = st.positionsDeg, let age = st.positionsAgeMs {
                let made = Date().addingTimeInterval(-Double(age) / 1000)
                if made >= moment || Date() > deadline { return (made, p) }
            }
            try await Task.sleep(for: .milliseconds(40))
        }
    }

    func freshPosition() async throws -> [Double] {
        // Up to 20 s: the hand controller can stall for several seconds.
        for _ in 0..<400 {
            if let p = try mount.status().positionsDeg { return p }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw MosaicError(description: "No position reads from the mount.")
    }

    /// The controller refuses a goto until a position has been read since
    /// the last move; that takes up to a quarter second.
    private func retrying(_ body: () throws -> Void) async throws {
        var last: Error?
        for _ in 0..<40 {
            do { return try body() } catch let e as MountSession.Failure
                where e.description.contains("wait a moment") || e.description.contains("not still")
            {
                last = e
                try await Task.sleep(for: .milliseconds(100))
            }
        }
        throw last ?? MosaicError(description: "the goto was refused")
    }

    private func waitForMotionToEnd() async throws {
        let end = Date().addingTimeInterval(30)
        while Date() < end {
            let s = try mount.status()
            for m in s.messages { onEvent(.message(m)) }
            switch s.state {
            case "Moving", "Stopping":
                try await Task.sleep(for: .milliseconds(40))
            case "FaultLatched":
                throw FaultStop(fault: s.lastFault)
            default:
                if s.lastRecord?.lastStage == "completed" || s.lastRecord?.lastStage == "cancelled"
                {
                    return
                }
                try await Task.sleep(for: .milliseconds(40))
            }
        }
        throw MosaicError(description: "The goto didn't finish in 30 s.")
    }

    /// A frame while tracking, with the mount's latest position and that
    /// read's own time: tracking holds the pointing against the Moon, so the
    /// read's time (not the frame's) is the one that pairs with it.
    private func trackedFrame() async throws -> (Frame, Date, [Double]) {
        try await Task.sleep(for: .seconds(settings.settleSeconds))
        let f = try await grabFrame()
        _ = f
        for _ in 0..<40 {
            let st = try mount.status()
            if let p = st.positionsDeg, let age = st.positionsAgeMs, age < 600 {
                return (f, clock().addingTimeInterval(-Double(age) / 1000), p)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let p = try await freshPosition()
        return (f, clock(), p)
    }

    /// A frame once the image has settled, with its time and the mount's position.
    private func still() async throws -> (Frame, Date, [Double]) {
        try await Task.sleep(for: .seconds(settings.settleSeconds))
        for _ in 0..<20 {
            if let f = try camera.frame(timeoutMs: 1_000) {
                // The frame's own time (the camera's wall clock), carried onto
                // the session's clock, on which the Moon's motion is computed.
                let taken = clock().addingTimeInterval(f.time.timeIntervalSinceNow)
                return (f, taken, try await freshPosition())
            }
        }
        throw MosaicError(description: "No frames from the camera.")
    }
}

func wrap180(_ d: Double) -> Double {
    let x = Ephemeris.normalize(d + 180) - 180
    return x
}

/// The image orientation a converging search tries before a calibration
/// (track 2, 2c): the guess, mirrored either way (a star diagonal), or
/// turned 180°.
public enum SearchOrientation: Sendable, CaseIterable, Equatable {
    case asGuessed, mirroredLeftRight, mirroredTopBottom, turned180

    /// Signs applied to the image offset's x and y before the guess.
    var flips: (x: Double, y: Double) {
        switch self {
        case .asGuessed: (1, 1)
        case .mirroredLeftRight: (-1, 1)
        case .mirroredTopBottom: (1, -1)
        case .turned180: (-1, -1)
        }
    }

    var next: SearchOrientation {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    public var label: String {
        switch self {
        case .asGuessed: "as guessed"
        case .mirroredLeftRight: "mirrored left-right"
        case .mirroredTopBottom: "mirrored top-bottom"
        case .turned180: "turned 180°"
        }
    }
}

/// The goto in progress (which axis, from and to, since when), shared with
/// the app for a progress bar.
public final class MotionInfo: @unchecked Sendable {
    public struct Move: Sendable {
        public let axis: Int
        public let from: Double
        public let to: Double
        public let started: Date
    }
    private let lock = NSLock()
    private var move: Move?
    public var current: Move? { lock.withLock { move } }
    func set(axis: Int, from: Double, to: Double) {
        lock.withLock { move = Move(axis: axis, from: from, to: to, started: Date()) }
    }
    func clear() { lock.withLock { move = nil } }
}

/// Whether camera frames are going to disk, and what for: the product
/// (mosaic video) or diagnostics (search, orientation, survey frames kept
/// for review). Shared with the app's status line.
public final class SavingInfo: @unchecked Sendable {
    public enum Purpose: Sendable, Equatable {
        case product(String)
        case diagnostic(String)
        public var text: String {
            switch self {
            case .product(let what): "Recording product: \(what)"
            case .diagnostic(let what): "Saving \(what) (for review)"
            }
        }
        public var isProduct: Bool { if case .product = self { true } else { false } }
    }
    private let lock = NSLock()
    private var active: Purpose?
    private var last: (purpose: Purpose, time: Date)?
    private var count = 0

    static func purpose(of sub: String) -> Purpose {
        switch sub {
        case "search": .diagnostic("search frames")
        case "orient": .diagnostic("orientation frames")
        case "survey": .diagnostic("Orient Moon survey frames")
        case "calibration": .diagnostic("calibration frames")
        default: .diagnostic("\(sub) frames")
        }
    }

    func begin(_ p: Purpose) { lock.withLock { active = p; count = 0 } }
    func end() { lock.withLock { if let a = active { last = (a, Date()) }; active = nil } }
    func saved(_ n: Int, purpose: Purpose?) {
        lock.withLock {
            count += n
            if let p = purpose ?? active { last = (p, Date()) }
        }
    }

    /// What is being saved now (a video in progress, or frames kept in the
    /// last two seconds), and the frames so far; nil when nothing is.
    public var now: (purpose: Purpose, frames: Int)? {
        lock.withLock {
            if let a = active { return (a, count) }
            if let l = last, Date().timeIntervalSince(l.time) < 2 { return (l.purpose, count) }
            return nil
        }
    }
}
