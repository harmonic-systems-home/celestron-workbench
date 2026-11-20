import Foundation

/// The sweep search (ADR 0022 amendment 7): each raster row is one steady
/// azimuth move on top of tracking, with the camera streaming, instead of
/// stop-and-shoot. The Moon (31′ and its glow) is far larger than the field,
/// so rows can be ~0.4° apart; at 1°/s a 2 ms exposure smears about 7″, and
/// at video rates the disk spans many frames. Every frame is checked; on a
/// sighting the mount stops, goes back to where that frame was taken (from
/// the sweep's own path: its start, its rate and the frame's time) and
/// converges onto the disk. Tracking under the sweep makes the pattern ride
/// on the Moon. Rows run back and forth from the start's row outward.
extension MosaicSession {
    public func searchSweep(
        halfWidthDeg: Double, halfHeightDeg: Double, rowSpacingDeg: Double = 0.4,
        speedDegS: Double = 1.0,
        converge: Converge? = nil,
        found: @escaping @Sendable (Blob.Found?) -> Bool,
        cancelled: @escaping @Sendable () -> Bool = { false },
        sighted: @escaping @Sendable () -> Bool = { false }
    ) async throws -> SearchOutcome {
        try camera.configure(exposureUs: settings.exposureUs, gain: settings.gain)
        try camera.start()
        defer { camera.stop() }
        let site = settings.site
        let alt0 = Self.moonAxes(at: clock(), site).alt
        let cosAlt = cos(alt0 * .pi / 180)
        let p0 = try await freshPosition()
        let searchStart = clock()
        let home = offset(of: p0, at: searchStart)

        // Rows: the start's row, then alternately above and below.
        // (A hair over, so 1.2 / 0.4 counts 3 rows each way, not 2.9999…:
        // 2026-11-20, rows stopped at ±0.8° of a ±1.2° area.)
        let rows = Int((halfHeightDeg / rowSpacingDeg + 1e-6).rounded(.down))
        var order = [0]
        for k in 1...max(rows, 1) where k <= rows {
            order += [k, -k]
        }
        // On the sky the row spans ±halfWidthDeg; on the azimuth axis, more.
        let halfAz = halfWidthDeg / cosAlt
        var pattern: [[Double]] = []
        var forward = true
        for k in order {
            let y = Double(k) * rowSpacingDeg
            pattern.append([forward ? -halfAz : halfAz, y])
            pattern.append([forward ? halfAz : -halfAz, y])
            forward.toggle()
        }
        let field = [
            Double(camera.info.width) * scaleGuessPublic / 3600,
            Double(camera.info.height) * scaleGuessPublic / 3600,
        ]
        var visited: [[Double]] = []
        var brightness: [Double] = []
        var caption = "Sweep"
        func progress(_ finished: Bool = false) {
            onEvent(
                .search(
                    SearchProgress(
                        pattern: pattern, visited: visited, brightness: brightness, fieldDeg: field,
                        altitudeDeg: alt0, start: p0, startTime: searchStart, followsMoon: true,
                        finished: finished, caption: finished ? "Sweep finished: \(caption)" : caption)))
        }
        progress()
        defer { progress(true) }

        /// Axis angles for a pattern point (degrees from the start, Moon frame) at `t`.
        func axes(_ pt: [Double], at t: Date) -> (az: Double, alt: Double) {
            let m = Self.moonAxes(at: t, site)
            return (Ephemeris.normalize(m.az + home.az + pt[0]), m.alt + home.alt + pt[1])
        }
        func trackMoon(extraAz: Double = 0) throws {
            let r = moonRate(at: clock())
            try mount.track(azDegS: r.az + extraAz, altDegS: r.alt)
        }
        // Moves between rows (and back to a sighting) are rate moves too:
        // the firmware's slow goto crawled (2026-11-20, simulator).
        func goto(_ pt: [Double]) async throws {
            try await rateMove(to: axes(pt, at: clock()), speedDegS: 1.5)
            try await Task.sleep(for: .milliseconds(Int(max(200, settings.settleSeconds * 600))))
        }

        // The whole search area first (Sun avoidance), row by row.
        do {
            let t = clock()
            try checkSun(path: [[p0[0], p0[1]]] + pattern.map { let a = axes($0, at: t); return [a.az, a.alt] }, what: "the search area")
        }
        onEvent(
            .message(
                String(
                    format: "Sweep search: %d rows %.2f° apart, ±%.1f° wide, at %.1f°/s.", order.count,
                    rowSpacingDeg, halfWidthDeg, speedDegS)))
        /// One sample along a line: where the frame was taken (pattern units,
        /// from the latest encoder read carried forward at the line's rate:
        /// a rate move's end isn't exact), and how much Moon it held.
        struct Sample {
            let x: Double
            let y: Double
            let share: Double
            let found: Bool
            let frame: Frame
        }
        /// Sweeps from `a` to `b` at `speed` (sky deg/s). `stop` sees every
        /// sample and ends the line early when it returns true.
        func line(
            _ a: [Double], _ b: [Double], speed: Double, stop: (Sample, [Sample]) -> Bool
        ) async throws -> [Sample] {
            try await goto(a)
            do {
                let t = clock()
                let (pa, pb) = (axes(a, at: t), axes(b, at: t))
                try checkSun(from: [pa.az, pa.alt], to: [pb.az, pb.alt], what: "the sweep")
            }
            let dAz = b[0] - a[0]
            let dAlt = b[1] - a[1]
            // Within the session's 2°/s on each axis: high up, azimuth runs
            // faster than the sky by 1/cos(altitude) (2026-11-20, the test
            // runner: refused above 60°).
            let moonNow = moonRate(at: clock())
            let duration = max(
                0.3, hypot(dAz * cosAlt, dAlt) / speed, abs(dAz) / (1.9 - abs(moonNow.az)),
                abs(dAlt) / (1.9 - abs(moonNow.alt)))
            let (rAz, rAlt) = (dAz / duration, dAlt / duration)
            let r = moonRate(at: clock())
            try mount.track(azDegS: r.az + rAz, altDegS: r.alt + rAlt)
            let wallStart = Date()
            var samples: [Sample] = []
            var lastReport = Date.distantPast
            defer { try? trackMoon() }
            while Date().timeIntervalSince(wallStart) < duration {
                if cancelled() { break }
                guard let f = try camera.frame(timeoutMs: 500) else { continue }
                let along = max(0, f.time.timeIntervalSince(wallStart))
                var (x, y) = (a[0] + rAz * along, a[1] + rAlt * along)
                if let st = try? mount.status(), let p = st.positionsDeg, let age = st.positionsAgeMs {
                    let readWall = Date().addingTimeInterval(-Double(age) / 1000)
                    let o = offset(of: p, at: clock().addingTimeInterval(-Double(age) / 1000))
                    let ahead = f.time.timeIntervalSince(readWall)
                    x = wrap180(o.az - home.az) + rAz * ahead
                    y = wrap180(o.alt - home.alt) + rAlt * ahead
                }
                let blob = Blob.find(f, thresholdFraction: 0.3)
                let sample = Sample(
                    x: x, y: y, share: found(blob) ? (blob?.litAboveSky ?? 0) : 0, found: found(blob), frame: f)
                samples.append(sample)
                if Date().timeIntervalSince(lastReport) > 0.15 || sample.found {
                    visited.append([x, y])
                    brightness.append(sample.found ? min(1, 0.4 + sample.share) : 0.05)
                    lastReport = Date()
                    progress()
                }
                if stop(sample, samples) || sighted() { break }
            }
            return samples
        }
        /// The middle of the stretch of a line that saw the Moon: where the
        /// line crosses the lit disk's middle (a chord's midpoint).
        func middle(_ samples: [Sample]) -> Sample? {
            let seen = samples.filter(\.found)
            guard let first = seen.first, let last = seen.last else { return nil }
            let mx = (first.x + last.x) / 2, my = (first.y + last.y) / 2
            let near = seen.min { hypot($0.x - mx, $0.y - my) < hypot($1.x - mx, $1.y - my) } ?? first
            return Sample(x: mx, y: my, share: near.share, found: true, frame: near.frame)
        }

        var sweeps = 0
        for i in stride(from: 0, to: pattern.count, by: 2) {
            if cancelled() || sighted() { break }
            let (a, b) = (pattern[i], pattern[i + 1])
            sweeps += 1
            caption = "Row \(sweeps) of \(order.count)"
            onEvent(.detail("Sweeping row \(sweeps) of \(order.count), watching the video"))
            // Along the row; once the Moon shows, carry on across it (up to
            // a Moon's width more) to find the middle of the crossing.
            var firstSeen: Sample?
            let moonDeg = 2 * Ephemeris.moon(at: clock(), from: site).diameterDeg / 2
            let row = try await line(a, b, speed: speedDegS) { s, all in
                if s.found, firstSeen == nil { firstSeen = s }
                guard let f = firstSeen else { return false }
                let past = hypot((s.x - f.x) * cosAlt, s.y - f.y)
                let top = all.map(\.share).max() ?? 0
                // Off the far side, or a Moon's width beyond the first sight.
                return past > moonDeg * 1.1 || (past > 0.1 && s.share < 0.3 * top)
            }
            guard let across = middle(row) else { continue }
            keep([("\(Self.fileStamp(clock()))-sweep-sighting", across.frame)], in: "search")
            onEvent(
                .message(
                    String(format: "Sweep: the Moon crossed row %d; now a short sweep up and down through it.", sweeps)))
            caption = "Row \(sweeps): across the Moon, up and down"
            onEvent(.detail("Found on row \(sweeps): sweeping up and down through it"))
            // Then up and down through the middle of that crossing.
            let half = moonDeg * 0.9
            let column = try await line(
                [across.x, across.y - half], [across.x, across.y + half], speed: speedDegS
            ) { _, _ in false }
            let centre = middle(column) ?? across
            if ProcessInfo.processInfo.environment["MOSAIC_DEBUG"] != nil {
                let rs = row.filter(\.found)
                print("DBG row found \(rs.count)/\(row.count) x \(rs.first?.x ?? .nan)…\(rs.last?.x ?? .nan) y \(rs.first?.y ?? .nan); across (\(across.x), \(across.y))")
                let cs = column.filter(\.found)
                print("DBG column found \(cs.count)/\(column.count) y \(cs.first?.y ?? .nan)…\(cs.last?.y ?? .nan) x \(column.first?.x ?? .nan); centre (\(centre.x), \(centre.y))")
            }
            // To the middle; if the Moon isn't in view there (a move's
            // error, or the middle fell on the dark side), to the brightest
            // place either sweep saw (2026-11-20, the test runner: a few
            // percent of searches were lost going back).
            var seen: Blob.Found?
            let brightest = (row + column).filter(\.found).max { $0.share < $1.share }
            for (k, aim) in [centre, brightest].compactMap({ $0 }).enumerated() {
                try await goto([aim.x, aim.y])
                try trackMoon()
                try await Task.sleep(for: .milliseconds(Int(max(300, settings.settleSeconds * 1000))))
                let now = try await grabFrame()
                let b = Blob.find(now, thresholdFraction: 0.3)
                if found(b) {
                    seen = b
                    break
                }
                if k == 0 { onEvent(.message("Sweep: not in view at the middle; going to the brightest place seen.")) }
            }
            guard let seen else {
                onEvent(.message("Sweep: lost it going back; carrying on with the search."))
                continue
            }
            if let p = try? await freshPosition() { markOnMoon(p, at: clock()) }
            // Before Orient camera nothing knows which way the image turns, so
            // stepping further would only be guessing (2026-11-20: 13 guessed
            // steps, then lost). In view, near the disk's middle, is enough.
            guard let converge, calibration != nil else {
                onEvent(.message("Sweep: the Moon is in view."))
                return SearchOutcome(
                    found: true, atAzAltDeg: try? await freshPosition(), blob: seen, stops: sweeps, converged: true)
            }
            var outcome = try await convergeOnDisk(from: seen, converge, cancelled)
            try trackMoon()
            outcome = SearchOutcome(
                found: true, atAzAltDeg: outcome.atAzAltDeg, blob: outcome.blob, stops: sweeps,
                converged: outcome.converged, convergeSteps: outcome.convergeSteps)
            return outcome
        }
        try? trackMoon()
        return SearchOutcome(found: false, atAzAltDeg: try? await freshPosition(), blob: nil, stops: sweeps)
    }

    /// Arcseconds per pixel: calibrated, or from the pixel size and focal length.
    var scaleGuessPublic: Double {
        calibration?.arcsecPerPixel ?? 206.265 * camera.info.pixelSizeUm / settings.focalLengthMm
    }
}
