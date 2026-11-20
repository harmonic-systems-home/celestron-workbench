import Foundation

public struct MosaicSettings: Sendable {
    public var site: Site
    /// The telescope's focal length, for the first guess at the image scale.
    public var focalLengthMm: Double = 2000
    public var overlap: Double = 0.25
    /// Each tile's video. No tracking runs, and the Moon drifts about 15″ a
    /// second, so keep it short; stacking aligns the frames.
    public var videoSeconds: Double = 3
    public var exposureUs: Int = 2_000
    public var gain: Int = 100
    /// Calibration moves, as a fraction of the frame's shorter side.
    public var calibrationFraction: Double = 0.2
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
    public private(set) var settings: MosaicSettings
    public private(set) var here: Here?
    public private(set) var calibration: CameraCalibration?
    /// The survey's fit, once the centre has been found.
    public private(set) var centreFit: MoonCentre.Fit?
    /// The survey's sunlit cells, relative to the Moon's centre.
    private var litSky: [SkyOffset] = []
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
    private let clock: @Sendable () -> Date
    private let onEvent: @Sendable (MosaicEvent) -> Void

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
        let now = clock()
        let sun = Ephemeris.sun(at: now)
        let (moonEq, _) = Ephemeris.moon(at: now)
        let separation = Ephemeris.separationDeg(sun, moonEq)
        guard separation >= settings.minSunSeparationDeg else {
            throw MosaicError(
                description: String(
                    format: "The Moon is %.0f° from the Sun: too close (at least %.0f°).",
                    separation, settings.minSunSeparationDeg))
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
    }

    /// The mount's axis angles that put `sky` (relative to the Moon's
    /// centre) in the middle of the frame at `time`.
    public func target(_ sky: SkyOffset, at time: Date) throws -> (az: Double, alt: Double) {
        guard let here else {
            throw MosaicError(description: "Centre the Moon and press Here first.")
        }
        let moon = Ephemeris.moon(at: time, from: settings.site).horizontal
        let dAz = wrap180(moon.azDeg - here.moon.horizontal.azDeg)
        let dAlt = moon.altDeg - here.moon.horizontal.altDeg
        let offset = MosaicPlanner.axes(for: sky, altitudeDeg: moon.altDeg)
        return (
            Ephemeris.normalize(here.azimuthDeg + dAz + offset.azDeg),
            here.altitudeDeg + dAlt
                + offset.altDeg
        )
    }

    // MARK: Calibration

    /// Two small gotos, one per axis; frames before and after each, registered,
    /// with the Moon's own motion meanwhile taken out.
    public func calibrate() async throws {
        guard here != nil else { throw MosaicError(description: "Press Here first.") }
        try await armForStep()
        defer { endStep() }
        try camera.configure(exposureUs: settings.exposureUs, gain: settings.gain)
        try camera.start()
        defer { camera.stop() }
        let move =
            settings.calibrationFraction * Double(min(camera.info.width, camera.info.height))
            * scaleGuess

        try await goToSky(SkyOffset(x: 0, y: 0))
        let (f0, t0, p0) = try await still()
        try await goBy(SkyOffset(x: move, y: 0))
        let (f1, t1, p1) = try await still()
        try await goBy(SkyOffset(x: 0, y: move))
        let (f2, t2, p2) = try await still()

        let s1 = relativeMove(from: (t0, p0), to: (t1, p1))
        let s2 = relativeMove(from: (t1, p1), to: (t2, p2))
        let r1 = Registration.shift(from: f0, to: f1)
        let r2 = Registration.shift(from: f1, to: f2)
        guard r1.peak > 0.05, r2.peak > 0.05,
            let cal = CameraCalibration(
                (s1, PixelOffset(x: r1.dx, y: r1.dy)), (s2, PixelOffset(x: r2.dx, y: r2.dy)))
        else {
            throw MosaicError(
                description: String(
                    format:
                        "Calibration failed: the frames didn't match (is the Moon in view and in focus?). Moves (%.0f″, %.0f″) → (%.0f, %.0f) px, match %.2f; (%.0f″, %.0f″) → (%.0f, %.0f) px, match %.2f.",
                    s1.x, s1.y, r1.dx, r1.dy, r1.peak, s2.x, s2.y, r2.dx, r2.dy, r2.peak))
        }
        calibration = cal
        // Back to the Moon's centre, where it started.
        try await goToSky(SkyOffset(x: 0, y: 0))
        onEvent(
            .message(
                String(
                    format:
                        "Calibration moves: (%.1f″, %.1f″) → (%.1f, %.1f) px; (%.1f″, %.1f″) → (%.1f, %.1f) px.",
                    s1.x, s1.y, r1.dx, r1.dy, s2.x, s2.y, r2.dx, r2.dy)))
        onEvent(
            .message(
                String(
                    format: "Calibrated: %.3f″ per pixel, camera turned %.1f°.", cal.arcsecPerPixel,
                    cal.rotationDeg)))
    }

    /// The change in pointing relative to the Moon between two moments, from
    /// the mount's own positions and the Moon's computed motion.
    public func relativeMove(from a: (Date, [Double]), to b: (Date, [Double])) -> SkyOffset {
        let ma = Ephemeris.moon(at: a.0, from: settings.site).horizontal
        let mb = Ephemeris.moon(at: b.0, from: settings.site).horizontal
        let dAz = wrap180(b.1[0] - a.1[0]) - wrap180(mb.azDeg - ma.azDeg)
        let dAlt = (b.1[1] - a.1[1]) - (mb.altDeg - ma.altDeg)
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
        cancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> SearchOutcome {
        let spiral = SpiralSearch(stepDeg: stepDeg, reachDeg: reachDeg)
        return try await walk(
            spiral.steps.map { ($0.azDeg, $0.altDeg) }, referenceAltitudeDeg, converge, found,
            cancelled)
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
        cancelled: @escaping @Sendable () -> Bool = { false }
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
        return try await walk(offsets, referenceAltitudeDeg, converge, found, cancelled)
    }

    /// Shared drive: arm, open the camera, goto each offset (from the start)
    /// in turn, and check the frame's brightest blob; then, with `converge`,
    /// step onto the disk.
    private func walk(
        _ offsets: [(Double, Double)],
        _ referenceAltitudeDeg: Double?,
        _ converge: Converge?,
        _ found: @escaping @Sendable (Blob.Found?) -> Bool,
        _ cancelled: @escaping @Sendable () -> Bool
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
        for (dAz, dAlt) in offsets {
            if cancelled() { break }
            // A search move is lean: a straight goto (no anti-backlash
            // overshoot — the search doesn't need backlash precision) and no
            // settle wait. A few-ms exposure freezes any residual motion, so
            // the brightness read is good the instant the move ends. This is
            // what keeps a 40-stop search to seconds, not minutes.
            try await searchGoTo(az: start[0] + dAz, alt: start[1] + dAlt)
            stops += 1
            let pos = try await freshPosition()
            let frame = try await grabFrame()
            // Acquisition detects a bright region against dark sky, so count
            // the whole lit target (a low fraction of its peak), not just its
            // brightest parts: brightFraction then reads as "how much of the
            // frame is lit".
            let blob = Blob.find(frame, thresholdFraction: 0.3)
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
        return SearchOutcome(
            found: false, atAzAltDeg: try? await freshPosition(), blob: nil, stops: stops)
    }

    /// Steps from a sighting onto the lit disk (`Converge`). Each step is one
    /// bounded, self-terminating search goto that moves the lit region's
    /// centroid to the frame's centre. Before a calibration the image's
    /// orientation is a guess that a star diagonal mirrors, so a step that
    /// loses ground (less of the frame lit, the centroid no nearer the
    /// centre) is undone and the next orientation tried: as guessed, mirrored
    /// left-right, mirrored top-bottom, turned 180°. The one that works is
    /// kept for later steps and for recentre. Runs inside `walk`'s armed step.
    private func convergeOnDisk(
        from sighting: Blob.Found, _ c: Converge,
        _ cancelled: @escaping @Sendable () -> Bool
    ) async throws -> SearchOutcome {
        let (w, h) = (Double(camera.info.width), Double(camera.info.height))
        let short = min(w, h)
        let maxStepPx = c.maxStepFrames * short
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
        while !onDisk(blob) {
            if cancelled() || steps >= c.maxSteps || failures >= SearchOrientation.allCases.count {
                break
            }
            // Move the centroid to the centre, at most one step's worth.
            var px = blob.offsetFromCentre
            let len = hypot(px.x, px.y)
            if len > maxStepPx { px = PixelOffset(x: px.x * maxStepPx / len, y: px.y * maxStepPx / len) }
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
            let next = lit(try await grabFrame())
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
            orientation = orientation.next
            onEvent(.message("Converge: that step lost ground; trying the image \(orientation.label)."))
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
        guard let calibration, let here else { throw MosaicError(description: "Calibrate first.") }
        let radius = here.moon.diameterDeg / 2 * 3600
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
        try await armForStep()
        defer { endStep() }
        try camera.configure(exposureUs: settings.surveyExposureUs, gain: settings.surveyGain)
        try camera.start()
        defer {
            camera.stop()
            try? camera.configure(exposureUs: settings.exposureUs, gain: settings.gain)
        }
        var samples: [MoonCentre.Sample] = []
        let origin = (here.time, [here.azimuthDeg, here.altitudeDeg])
        for (i, stop) in stops.enumerated() {
            // One goto, no touch-ups: where it really pointed is read below.
            let aim = try target(stop, at: clock().addingTimeInterval(settings.settleSeconds + 1))
            try await goTo(az: aim.az, alt: aim.alt)
            let (frame, t, p) = try await still()
            // Where the camera really pointed, from the mount's own position.
            let pointing = relativeMove(from: origin, to: (t, p))
            samples += MoonCentre.samples(
                frame, pointing: pointing, calibration: calibration,
                cellPixels: Int((25 / calibration.arcsecPerPixel).rounded()))
            if (i + 1) % 10 == 0 { onEvent(.message("Survey: \(i + 1) of \(stops.count).")) }
        }
        guard
            let fit = MoonCentre.fit(samples, radiusArcsec: radius, searchArcsec: 1.1 * radius),
            fit.agreement > 0.85
        else {
            try await goToSky(SkyOffset(x: 0, y: 0))
            throw MosaicError(
                description:
                    "Couldn't find the Moon's edge in the survey. Is Here on the lit Moon, and the survey exposure right (Settings)?")
        }
        // Here moves to the centre: the same moment, the axes shifted.
        let shift = MosaicPlanner.axes(for: fit.centre, altitudeDeg: here.moon.horizontal.altDeg)
        self.here = Here(
            time: here.time, azimuthDeg: Ephemeris.normalize(here.azimuthDeg + shift.azDeg),
            altitudeDeg: here.altitudeDeg + shift.altDeg, moon: here.moon)
        litSky = samples.filter { $0.mean >= fit.levels.lit }.map {
            SkyOffset(x: $0.sky.x - fit.centre.x, y: $0.sky.y - fit.centre.y)
        }
        centreFit = fit
        plan = nil
        // The altitude reference was set off-centre at Here: set it again,
        // from where the mount points now against where the centre is.
        let now = clock()
        let pos = try await freshPosition()
        let centreNow = try target(SkyOffset(x: 0, y: 0), at: now)
        let moonNow = Ephemeris.moon(at: now, from: settings.site).horizontal
        try mount.setAltitudeReference(moonNow.altDeg + (pos[1] - centreNow.alt))
        try await goToSky(SkyOffset(x: 0, y: 0))
        onEvent(
            .message(
                String(
                    format:
                        "Centre found %.0f″ from Here (%.0f″, %.0f″); %.0f%% of cells agree; %@.",
                    hypot(fit.centre.x, fit.centre.y), fit.centre.x, fit.centre.y,
                    fit.agreement * 100,
                    fit.earthshine ? "earthshine seen" : "no earthshine above the sky")))
        return fit
    }

    // MARK: Plan and run

    /// Plans the tiles around Here. Without a centre fit, Here is wherever
    /// the operator (or a search) left the mount, so the grid can sit off
    /// the disk (2026-11-17: ~0.7 Moon radii high). That needs
    /// `allowWithoutCentre`: the app asks the operator first.
    @discardableResult
    public func makePlan(allowWithoutCentre: Bool = false) throws -> MosaicPlan {
        guard let calibration, let here else { throw MosaicError(description: "Calibrate first.") }
        guard centreFit != nil || allowWithoutCentre else {
            throw MosaicError(
                description:
                    "Find centre hasn't succeeded, so the plan would be centred on Here, which may be off the Moon's centre.")
        }
        var plan = MosaicPlanner.plan(
            moonDiameterDeg: here.moon.diameterDeg, calibration: calibration,
            frameWidth: camera.info.width, frameHeight: camera.info.height,
            overlap: settings.overlap)
        if centreFit != nil {
            plan = MosaicPlanner.markLit(plan, litSky: litSky, calibration: calibration)
        }
        self.plan = plan
        states = Dictionary(uniqueKeysWithValues: plan.tiles.map { ($0.id, .pending) })
        stacks = [:]
        let lit = plan.tiles.filter(\.lit).count
        onEvent(
            .message(
                lit == plan.tiles.count
                    ? "Plan: \(plan.tiles.count) tiles."
                    : "Plan: \(lit) lit tiles, and \(plan.tiles.count - lit) dark ones for earthshine."))
        return plan
    }

    /// Captures `tiles` (all not yet done, by default) into `folder`, one SER
    /// each. `shouldContinue` is checked between tiles (pause, stop).
    public func run(
        tiles: [Int]? = nil, into folder: URL, shouldContinue: @Sendable () -> Bool = { true }
    ) async throws {
        guard let plan else { throw MosaicError(description: "Plan first.") }
        try await armForStep()
        defer { endStep() }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try camera.configure(exposureUs: settings.exposureUs, gain: settings.gain)
        let log = SessionLog(folder: folder)
        if loggedPlanIn != folder, let calibration, let here {
            record {
                try log.plan(
                    plan, calibration: calibration, moonDiameterDeg: here.moon.diameterDeg,
                    colorID: SerWriter.colorID(for: camera.info), time: clock())
            }
            loggedPlanIn = folder
        }
        let ids =
            tiles
            ?? plan.tiles.filter(\.lit).map(\.id).filter {
                if case .done = states[$0] { return false } else { return true }
            }
        for id in ids {
            guard shouldContinue() else { break }
            guard let tile = plan.tiles.first(where: { $0.id == id }) else { continue }
            do {
                set(id, .moving)
                try await goToSky(tile.pointing)
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
        let end = clock().addingTimeInterval(settings.videoSeconds)
        // The first and last frames' times, on the session's clock.
        var first: Date?
        var last = Date()
        while clock() < end {
            guard let frame = try camera.frame(timeoutMs: 500) else { continue }
            last = clock().addingTimeInterval(frame.time.timeIntervalSinceNow)
            if first == nil { first = last }
            try writer.append(frame)
            stack.offer(frame)
            await Task.yield()
        }
        let frames = writer.frameCount
        try writer.finish()
        guard frames > 0, let first else {
            throw MosaicError(description: "No frames arrived from the camera.")
        }
        stacks[tile.id] = stack
        // The mount holds still through the video, so one read serves; the
        // Moon's part at the frame's centre is taken midway between the first
        // and last frames.
        let position = try? mount.status().positionsDeg
        var measured: PixelOffset?
        if let position, let here, let calibration {
            let sky = relativeMove(
                from: (here.time, [here.azimuthDeg, here.altitudeDeg]),
                to: (first.addingTimeInterval(last.timeIntervalSince(first) / 2), position))
            let p = calibration.image(for: sky)
            measured = PixelOffset(x: -p.x, y: -p.y)
        }
        return (name, frames, stack.bestSharpness, first, last, position, measured)
    }

    // MARK: Moving

    /// One re-aim at the Moon's centre, for Hold.
    public func hold() async throws {
        guard here != nil else { throw MosaicError(description: "Press Here first.") }
        try await armForStep()
        defer { endStep() }
        try await goToSky(SkyOffset(x: 0, y: 0))
    }

    /// Arms the mount for a step's moves. Arming wants fresh, steady
    /// position reads, so a refusal is retried for a few seconds (the keys
    /// may have just been used).
    func armForStep() async throws {
        let s = try mount.status()
        switch s.state {
        case "Armed": return
        case "FaultLatched":
            throw MosaicError(
                description:
                    "The mount is latched on a fault (\(s.lastFault?.detail ?? "?")): press Reset first.")
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
                y: (check.alt - p[1]) * 3600)
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
            let position = try await freshPosition()
            let delta = wrap180(target - position[axis == .azimuth ? 0 : 1])
            if abs(delta) < 0.000_05 { continue }
            let way = axis == .azimuth ? approach.az : approach.alt
            try await retrying { try self.mount.goto(axis, by: delta, approach: way) }
            try await waitForMotionToEnd()
            if ProcessInfo.processInfo.environment["MOSAIC_DEBUG"] != nil {
                let st = try mount.status()
                onEvent(
                    .message(
                        "goto \(axis) \(delta)° from \(position) → \(st.positionsDeg ?? []) (age \(st.positionsAgeMs ?? -1) ms, \(st.lastRecord?.lastStage ?? "?"))"
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
            let position = try await freshPosition()
            let delta = wrap180(target - position[axis == .azimuth ? 0 : 1])
            if abs(delta) < 0.000_05 { continue }
            try await retrying { try self.mount.goto(axis, by: delta, approach: nil) }
            try await waitForMotionToEnd()
        }
    }

    /// The latest camera frame, without waiting for the image to settle.
    private func grabFrame() async throws -> Frame {
        for _ in 0..<20 {
            if let f = try camera.frame(timeoutMs: 1_000) { return f }
        }
        throw MosaicError(description: "No frames from the camera.")
    }

    private func freshPosition() async throws -> [Double] {
        for _ in 0..<100 {
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
                throw MosaicError(
                    description: "The mount stopped on a fault: \(s.lastFault?.detail ?? "?")")
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
