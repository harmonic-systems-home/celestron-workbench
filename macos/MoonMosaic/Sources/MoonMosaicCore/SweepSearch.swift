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
        let rows = Int((halfHeightDeg / rowSpacingDeg).rounded(.down))
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
        func progress(_ finished: Bool = false) {
            onEvent(
                .search(
                    SearchProgress(
                        pattern: pattern, visited: visited, brightness: brightness, fieldDeg: field,
                        altitudeDeg: alt0, start: p0, startTime: searchStart, followsMoon: true,
                        finished: finished)))
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

        onEvent(
            .message(
                String(
                    format: "Sweep search: %d rows %.2f° apart, ±%.1f° wide, at %.1f°/s.", order.count,
                    rowSpacingDeg, halfWidthDeg, speedDegS)))
        var sweeps = 0
        for i in stride(from: 0, to: pattern.count, by: 2) {
            if cancelled() { break }
            let (a, b) = (pattern[i], pattern[i + 1])
            try await goto(a)
            // The sweep: Moon's rate plus the row's.
            let dir = b[0] > a[0] ? 1.0 : -1.0
            let azRate = dir * speedDegS / cosAlt
            let duration = abs(b[0] - a[0]) / abs(azRate)
            // Where the sweep is at wall time t: from the row's start.
            let startAxes = axes(a, at: clock())
            try trackMoon(extraAz: azRate)
            let wallStart = Date()
            sweeps += 1
            var hit: (Frame, Blob.Found, Double)?
            var rowY = a[1]
            var lastReport = Date.distantPast
            var best: (Double, Double)?  // score, sweep x at it
            while Date().timeIntervalSince(wallStart) < duration {
                if cancelled() { break }
                guard let f = try camera.frame(timeoutMs: 500) else { continue }
                // Where along the row this frame was taken (pattern units):
                // from the latest encoder read, carried forward at the sweep's
                // rate to the frame's moment (the move to the row's start
                // isn't exact, so the row's own start can't be trusted).
                var x = a[0] + dir * max(0, f.time.timeIntervalSince(wallStart)) * abs(azRate)
                if let st = try? mount.status(), let p = st.positionsDeg, let age = st.positionsAgeMs {
                    let readWall = Date().addingTimeInterval(-Double(age) / 1000)
                    let readSession = clock().addingTimeInterval(-Double(age) / 1000)
                    let o = offset(of: p, at: readSession)
                    x = wrap180(o.az - home.az) + azRate * f.time.timeIntervalSince(readWall)
                    rowY = o.alt - home.alt
                }
                let blob = Blob.find(f, thresholdFraction: 0.3)
                let score = Double(blob?.peak ?? 0) / 255 * min(1, (blob?.litAboveSky ?? 0) * 3)
                if score > (best?.0 ?? 0) { best = (score, x) }
                if Date().timeIntervalSince(lastReport) > 0.15 {
                    visited.append([x, rowY])
                    brightness.append(score)
                    lastReport = Date()
                    progress()
                }
                if found(blob), let blob {
                    hit = (f, blob, x)
                    break
                }
                if sighted() {
                    // The operator saw it: the brightest place on this row so far.
                    if let best { hit = (f, blob ?? Blob.Found(x: 0, y: 0, offsetFromCentre: PixelOffset(x: 0, y: 0), peak: 0, meanAbove: 0, pixels: 0, brightFraction: 0), best.1) }
                    break
                }
            }
            try trackMoon()
            _ = startAxes
            if let (f, blob, x) = hit {
                visited.append([x, rowY])
                brightness.append(1)
                onEvent(
                    .message(
                        String(format: "Sweep: the Moon came into view on row %d; going back to that spot.", sweeps)))
                keep([("\(Self.fileStamp(clock()))-sweep-sighting", f)], in: "search")
                try await goto([x, rowY])
                try trackMoon()
                try await Task.sleep(for: .milliseconds(Int(max(300, settings.settleSeconds * 1000))))
                let now = try await grabFrame()
                let seen = Blob.find(now, thresholdFraction: 0.3) ?? blob
                // Found: the Moon is in view. Before Orient camera nothing
                // knows which way the image turns, so stepping further would
                // only be guessing (2026-11-20: 13 guessed steps, then lost).
                // In view is enough: Orient camera works from here.
                guard let converge, calibration != nil else {
                    let inView = found(seen)
                    onEvent(.message(inView ? "Sweep: the Moon is in view." : "Sweep: lost it going back; search again."))
                    return SearchOutcome(
                        found: inView, atAzAltDeg: try? await freshPosition(), blob: seen, stops: sweeps,
                        converged: inView)
                }
                var outcome = try await convergeOnDisk(from: seen, converge, cancelled)
                try trackMoon()
                outcome = SearchOutcome(
                    found: true, atAzAltDeg: outcome.atAzAltDeg, blob: outcome.blob, stops: sweeps,
                    converged: outcome.converged, convergeSteps: outcome.convergeSteps)
                return outcome
            }
            if sighted() { break }
        }
        try? trackMoon()
        return SearchOutcome(found: false, atAzAltDeg: try? await freshPosition(), blob: nil, stops: sweeps)
    }

    /// Arcseconds per pixel: calibrated, or from the pixel size and focal length.
    var scaleGuessPublic: Double {
        calibration?.arcsecPerPixel ?? 206.265 * camera.info.pixelSizeUm / settings.focalLengthMm
    }
}
