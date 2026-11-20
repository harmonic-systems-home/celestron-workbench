import Foundation

/// Orient Camera (ADR 0022 amendment 7): how the camera sees the sky, from
/// the Moon's own motion. Needs no Here and no focal length.
/// 1. **Drift.** From the Moon held by tracking, tracking pauses and frames
///    follow its drift. The ephemeris gives the motion exactly, so the
///    image's motion gives the scale and the camera's turn.
/// 2. **Back.** A goto to where the scope was against the Moon (Undo's move),
///    and tracking again.
/// 3. **One nudge across the drift.** Extra tracking rate for a moment: the
///    image moves one way if the camera sees the sky directly and the other
///    way if it is mirrored (a star diagonal). That settles mirroring.
/// 4. **Back again**, and tracking on.
extension MosaicSession {
    public struct Orientation: Sendable {
        public let calibration: CameraCalibration
        public let driftArcsecPerPixel: Double
        /// How far the nudge's measured shift was from each prediction (a
        /// fraction of its length): the chosen one must fit and the other not.
        public let errorDirect: Double
        public let errorMirrored: Double
    }

    /// The pointing's change against the Moon between two readings, on the
    /// sky (arcseconds, x along azimuth, y up): the mount's move minus the
    /// Moon's motion meanwhile.
    func skyChange(from a: (Date, [Double]), to b: (Date, [Double])) -> SkyOffset {
        let oa = offset(of: a.1, at: a.0)
        let ob = offset(of: b.1, at: b.0)
        let alt = Self.moonAxes(at: b.0, settings.site).alt
        return SkyOffset(x: wrap180(ob.az - oa.az) * cos(alt * .pi / 180) * 3600, y: wrap180(ob.alt - oa.alt) * 3600)
    }

    @discardableResult
    public func orientCamera() async throws -> Orientation {
        try camera.configure(exposureUs: settings.exposureUs, gain: settings.gain)
        try camera.start()
        defer { camera.stop() }
        let guess = 206.265 * camera.info.pixelSizeUm / settings.focalLengthMm
        let short = Double(min(camera.info.width, camera.info.height))
        let stamp = Self.fileStamp(clock())

        func trackMoon(extra: SkyOffset = SkyOffset(x: 0, y: 0)) throws {
            if (try? mount.status().state) == "Armed" { endStep() }
            let r = moonRate(at: clock())
            let alt = Self.moonAxes(at: clock(), settings.site).alt
            let e = MosaicPlanner.axes(for: extra, altitudeDeg: alt)
            try mount.track(azDegS: r.az + e.azDeg, altDegS: r.alt + e.altDeg)
        }
        func reading() async throws -> (Date, [Double]) {
            let st = try mount.status()
            if let p = st.positionsDeg, let age = st.positionsAgeMs {
                return (clock().addingTimeInterval(-Double(age) / 1000), p)
            }
            return (clock(), try await freshPosition())
        }
        func back(to home: FollowState.Offset) async throws {
            let m = Self.moonAxes(at: clock().addingTimeInterval(3), settings.site)
            try await armForStep()
            for (axis, target) in [
                (MountSession.Axis.azimuth, Ephemeris.normalize(m.az + home.az)), (.altitude, m.alt + home.alt),
            ] {
                try await moveAxis(axis, to: target, approach: nil)
            }
            endStep()
            try trackMoon()
            // Let the tube stop ringing after the goto.
            try await Task.sleep(for: .milliseconds(max(500, Int(settings.settleSeconds * 2000))))
        }

        var why = ""
        for attempt in 1...3 {
            // Held on the Moon, wherever it is now.
            try trackMoon()
            try await Task.sleep(for: .milliseconds(600))
            let start = try await reading()
            let home = offset(of: start.1, at: start.0)

            // 1. Drift.
            try mount.stopTracking()
            try await Task.sleep(for: .milliseconds(500))
            var drift: [(Frame, (Date, [Double]))] = []
            let t0 = Date()
            let step = settings.driftSeconds / Double(settings.driftFrames)
            for n in 0...settings.driftFrames {
                onEvent(
                    .detail(
                        String(
                            format: "Drifting (tracking paused): frame %d of %d, %.0f s left", n + 1,
                            settings.driftFrames + 1, Double(settings.driftFrames - n) * step)))
                let wait = t0.addingTimeInterval(Double(n) * step).timeIntervalSinceNow
                if wait > 0 { try await Task.sleep(for: .seconds(wait)) }
                let f = try await grabFrame()
                let r = try await reading()
                // The frame's moment, with the (still) mount's position.
                drift.append((f, (clock().addingTimeInterval(f.time.timeIntervalSinceNow), r.1)))
            }
            keep(drift.enumerated().map { ("\(stamp)-o\(attempt)-drift\(String(format: "%02d", $0.offset))", $0.element.0) }, in: "orient")
            var dSky = SkyOffset(x: 0, y: 0)
            var dPx = PixelOffset(x: 0, y: 0)
            var used = 0
            var records: [[String: Any]] = []
            for (a, b) in zip(drift, drift.dropFirst()) {
                let sky = skyChange(from: a.1, to: b.1)
                let expected = hypot(sky.x, sky.y) / guess
                let r = Registration.shift(from: a.0, to: b.0, minShift: max(6, 0.25 * expected))
                let ok = r.peak > 0.05
                records.append(["sky": [sky.x, sky.y], "shift": [r.dx, r.dy, r.peak], "used": ok])
                if ok {
                    dSky = SkyOffset(x: dSky.x + sky.x, y: dSky.y + sky.y)
                    dPx = PixelOffset(x: dPx.x + r.dx, y: dPx.y + r.dy)
                    used += 1
                }
            }
            // 2. Back, tracking.
            onEvent(.detail("Back to where it was, tracking again"))
            try await back(to: home)
            guard used >= 2, hypot(dPx.x, dPx.y) > 10 else {
                why = "the drift couldn't be followed (\(used) of \(settings.driftFrames) steps matched)"
                note("orient", ["time": stamp, "attempt": attempt, "drift": records, "result": why])
                onEvent(.message("Orient camera attempt \(attempt) of 3: \(why); trying again."))
                continue
            }
            let scale = hypot(dSky.x, dSky.y) / hypot(dPx.x, dPx.y)
            // The two maps the drift allows: a turn and a scale, seen directly
            // or mirrored (reflected across the image's x axis, then turned).
            func similarity(mirrored: Bool) -> CameraCalibration {
                let k = hypot(dPx.x, dPx.y) / hypot(dSky.x, dSky.y)
                let s = mirrored ? SkyOffset(x: dSky.x, y: -dSky.y) : dSky
                let phi = atan2(dPx.y, dPx.x) - atan2(s.y, s.x)
                let (c, sn) = (cos(phi) * k, sin(phi) * k)
                // M = k R(phi) F, F = diag(1, −1) when mirrored.
                let f = mirrored ? -1.0 : 1.0
                return CameraCalibration(a: c, b: -sn * f, c: sn, d: c * f)
            }
            // (Which one is "mirrored" is the map's own determinant: the
            // image's y runs down while the sky's runs up.)
            let candidates = [similarity(mirrored: false), similarity(mirrored: true)]
            let direct = candidates.first { !$0.mirrored } ?? candidates[0]
            let mirrored = candidates.first { $0.mirrored } ?? candidates[1]

            // 3. One nudge across the drift, about an eighth of the frame.
            onEvent(.detail("One nudge across the drift, to tell mirrored from direct"))
            let size = 0.12 * short * scale
            let n = hypot(dSky.x, dSky.y)
            let across = SkyOffset(x: -dSky.y / n * size, y: dSky.x / n * size)
            let (f0, _) = (try await grabFrame(), ())
            let r0 = try await reading()
            let seconds = 2.0
            try trackMoon(extra: SkyOffset(x: across.x / seconds, y: across.y / seconds))
            try await Task.sleep(for: .seconds(seconds))
            try trackMoon()
            try await Task.sleep(for: .milliseconds(600))
            let r1 = try await reading()
            let f1 = try await grabFrame()
            keep([("\(stamp)-o\(attempt)-nudge-0", f0), ("\(stamp)-o\(attempt)-nudge-1", f1)], in: "orient")
            let nSky = skyChange(from: r0, to: (clock().addingTimeInterval(f1.time.timeIntervalSinceNow), r1.1))
            let expected = hypot(nSky.x, nSky.y) / scale
            let shift = Registration.shift(from: f0, to: f1, minShift: max(6, 0.25 * expected))
            // 4. Back again.
            onEvent(.detail("Back again"))
            try await back(to: home)
            onEvent(.detail(nil))

            func error(_ m: CameraCalibration) -> Double {
                let q = m.image(for: nSky)
                return hypot(q.x - shift.dx, q.y - shift.dy) / max(1, hypot(q.x, q.y))
            }
            let (eD, eM) = (error(direct), error(mirrored))
            why = String(
                format: "drift %d steps, %.0f″ → %.0f px (%.3f″/px); nudge (%.0f″, %.0f″) → (%.0f, %.0f) px, match %.2f; off by %.0f%% direct, %.0f%% mirrored",
                used, n, hypot(dPx.x, dPx.y), scale, nSky.x, nSky.y, shift.dx, shift.dy, shift.peak, eD * 100, eM * 100)
            note(
                "orient",
                [
                    "time": stamp, "attempt": attempt, "drift": records, "scale": scale,
                    "nudge": ["sky": [nSky.x, nSky.y], "shift": [shift.dx, shift.dy, shift.peak]],
                    "errorDirect": eD, "errorMirrored": eM, "guessArcsecPerPixel": guess,
                ])
            let best = min(eD, eM)
            guard shift.peak > 0.05, best <= 0.3, max(eD, eM) >= 2 * best + 0.2 else {
                onEvent(.message("Orient camera attempt \(attempt) of 3 didn't settle (\(why)); trying again."))
                continue
            }
            let m = eD <= eM ? direct : mirrored
            calibration = m
            onEvent(
                .message(
                    String(
                        format: "Camera oriented: %.3f″ per pixel (%+.0f%% against %.3f from the %.0f mm focal length), turned %.1f°, %@. (%@)",
                        m.arcsecPerPixel, (m.arcsecPerPixel / guess - 1) * 100, guess, settings.focalLengthMm,
                        m.rotationDeg, m.mirrored ? "mirrored (a diagonal)" : "not mirrored", why)))
            if abs(m.arcsecPerPixel / guess - 1) > 0.25 {
                onEvent(.message("The scale differs from the focal length's by more than 25%: a Barlow or reducer? If not, check the focal length in Settings."))
            }
            return Orientation(calibration: m, driftArcsecPerPixel: scale, errorDirect: eD, errorMirrored: eM)
        }
        throw MosaicError(description: "Orient camera failed 3 times (\(why)). Put Moon detail (the terminator is best) in view and try again.")
    }
}
