import Foundation

/// The Moon's sharp sunlit limb in a frame, and the circle through it
/// (Orient Moon's limb probe). The limb is where bright Moon meets dark sky
/// within a few pixels; the glow beside it fades over many, so it never
/// passes for an edge (2026-11-20, first night: fits that counted faint
/// cells as Moon were pulled 256″ toward the bright limb, while a circle
/// through the sharp edges came out at 963″ against the ephemeris's 964″).
public enum LimbEdge {
    /// One edge point: where it is on the sky (arcseconds, the same frame as
    /// the pointing) and which way the sky lies (unit vector, bright to dark).
    public struct Point: Sendable, Equatable {
        public let sky: SkyOffset
        public let outward: SkyOffset
    }

    /// Edge points in `frame`, taken with the camera at `pointing`. A part
    /// of the sky at s appears at pixel M·(pointing − s) from the centre,
    /// so a pixel u sees s = pointing − M⁻¹u. With `outward`, only edges
    /// whose sky side faces within about 60° of it are kept (the sunlit limb
    /// being probed, not the terminator or a shadow).
    public static func points(
        _ frame: Frame, pointing: SkyOffset, calibration: CameraCalibration, outward: SkyOffset? = nil,
        bin: Int = 4
    ) -> [Point] {
        let (bw, bh) = (frame.width / bin, frame.height / bin)
        guard bw > 20, bh > 20 else { return [] }
        // Binned: every colour of a Bayer sensor in each, and less noise.
        var g = [Double](repeating: 0, count: bw * bh)
        for y in 0..<bh {
            for x in 0..<bw {
                var s = 0
                for dy in 0..<bin {
                    let row = (y * bin + dy) * frame.width + x * bin
                    for dx in 0..<bin { s += Int(frame.pixels[row + dx]) }
                }
                g[y * bw + x] = Double(s) / Double(bin * bin)
            }
        }
        let sorted = g.sorted()
        let lo = sorted[sorted.count / 20]
        let hi = sorted[sorted.count * 19 / 20]
        let contrast = hi - lo
        guard contrast > 20 else { return [] }
        let k = 6
        var out: [Point] = []
        let half = (x: Double(frame.width) / 2, y: Double(frame.height) / 2)
        let dir = outward.map { v -> SkyOffset in
            let n = max(1e-9, hypot(v.x, v.y))
            return SkyOffset(x: v.x / n, y: v.y / n)
        }
        for y in stride(from: k + 1, to: bh - k - 1, by: 1) {
            for x in stride(from: k + 1, to: bw - k - 1, by: 1) {
                let gx = (g[y * bw + x + 1] - g[y * bw + x - 1]) / 2
                let gy = (g[(y + 1) * bw + x] - g[(y - 1) * bw + x]) / 2
                let mag = hypot(gx, gy)
                guard mag > 0.05 * contrast else { continue }
                let (nx, ny) = (gx / mag, gy / mag)  // toward brighter
                func at(_ s: Double) -> Double {
                    let xi = min(bw - 1, max(0, Int((Double(x) + nx * s).rounded())))
                    let yi = min(bh - 1, max(0, Int((Double(y) + ny * s).rounded())))
                    return g[yi * bw + xi]
                }
                let (bright, dark) = (at(Double(k)), at(-Double(k)))
                guard bright >= lo + 0.5 * contrast, dark <= lo + 0.12 * contrast else { continue }
                // Only the edge's steepest pixel across it.
                let ahead = abs(at(2) - at(0)) / 2
                let behind = abs(at(0) - at(-2)) / 2
                guard mag >= ahead, mag >= behind else { continue }
                let u = PixelOffset(
                    x: (Double(x) + 0.5) * Double(bin) - half.x, y: (Double(y) + 0.5) * Double(bin) - half.y)
                let d = calibration.sky(for: u)
                // The sky side, on the sky: features at s sit at M·(p − s),
                // so a step du in the image is −M⁻¹du on the sky.
                let o = calibration.sky(for: PixelOffset(x: nx, y: ny))  // n points to the bright side
                let on = max(1e-9, hypot(o.x, o.y))
                let outwardSky = SkyOffset(x: o.x / on, y: o.y / on)
                if let dir, outwardSky.x * dir.x + outwardSky.y * dir.y < 0.5 { continue }
                out.append(Point(sky: SkyOffset(x: pointing.x - d.x, y: pointing.y - d.y), outward: outwardSky))
            }
        }
        return out
    }

    public struct Circle: Sendable, Equatable {
        public let centre: SkyOffset
        /// The radius fitted freely to the same points: a check on the fit.
        public let freeRadius: Double
        public let inliers: Int
        public let total: Int
        /// RMS distance of the inliers from the circle (″).
        public let rms: Double
    }

    /// The circle of `radius` through `points`, starting from `start` and
    /// rejecting outliers step by step (60″, 25″, then 12″ from the circle).
    public static func fit(_ points: [Point], radius r: Double, start: SkyOffset) -> Circle? {
        guard points.count >= 10 else { return nil }
        var c = start
        var inl = points
        for tol in [400.0, 150.0, 60.0, 25.0, 12.0] {
            inl = points.filter { abs(hypot($0.sky.x - c.x, $0.sky.y - c.y) - r) < tol }
            guard inl.count >= 10 else { return nil }
            // Gauss–Newton on Σ(|p − c| − r)².
            for _ in 0..<10 {
                var (a11, a12, a22, b1, b2) = (0.0, 0.0, 0.0, 0.0, 0.0)
                for p in inl {
                    let dx = c.x - p.sky.x
                    let dy = c.y - p.sky.y
                    let d = max(1e-6, hypot(dx, dy))
                    let (jx, jy) = (dx / d, dy / d)
                    let res = d - r
                    a11 += jx * jx
                    a12 += jx * jy
                    a22 += jy * jy
                    b1 += jx * res
                    b2 += jy * res
                }
                let det = a11 * a22 - a12 * a12
                guard abs(det) > 1e-9 else { break }
                let sx = (a22 * b1 - a12 * b2) / det
                let sy = (-a12 * b1 + a11 * b2) / det
                c = SkyOffset(x: c.x - sx, y: c.y - sy)
                if hypot(sx, sy) < 0.01 { break }
            }
        }
        inl = points.filter { abs(hypot($0.sky.x - c.x, $0.sky.y - c.y) - r) < 12 }
        guard inl.count >= 10 else { return nil }
        // Free radius: the algebraic circle through the inliers.
        var (sxx, sxy, syy, sx, sy, n) = (0.0, 0.0, 0.0, 0.0, 0.0, 0.0)
        var (sxz, syz, sz) = (0.0, 0.0, 0.0)
        for p in inl {
            let (x, y) = (p.sky.x - c.x, p.sky.y - c.y)
            let z = x * x + y * y
            sxx += x * x; sxy += x * y; syy += y * y; sx += x; sy += y; n += 1
            sxz += x * z; syz += y * z; sz += z
        }
        // Solve [sxx sxy sx; sxy syy sy; sx sy n]·[2a 2b c] = [sxz syz sz].
        let m = [[sxx, sxy, sx], [sxy, syy, sy], [sx, sy, n]]
        let v = [sxz, syz, sz]
        func det3(_ a: [[Double]]) -> Double {
            a[0][0] * (a[1][1] * a[2][2] - a[1][2] * a[2][1]) - a[0][1] * (a[1][0] * a[2][2] - a[1][2] * a[2][0])
                + a[0][2] * (a[1][0] * a[2][1] - a[1][1] * a[2][0])
        }
        let d0 = det3(m)
        var free = r
        if abs(d0) > 1e-9 {
            var sol = [0.0, 0.0, 0.0]
            for i in 0..<3 {
                var mi = m
                for j in 0..<3 { mi[j][i] = v[j] }
                sol[i] = det3(mi) / d0
            }
            let (a, b) = (sol[0] / 2, sol[1] / 2)
            let rr = sol[2] + a * a + b * b
            if rr > 0 { free = rr.squareRoot() }
        }
        let rms = (inl.map { pow(hypot($0.sky.x - c.x, $0.sky.y - c.y) - r, 2) }.reduce(0, +) / Double(inl.count))
            .squareRoot()
        return Circle(centre: c, freeRadius: free, inliers: inl.count, total: points.count, rms: rms)
    }
}

extension MosaicSession {
    /// Orient Moon's limb probe: from Here (on the Moon), three short lines
    /// out across the sunlit limb (toward the bright limb and 65° either
    /// side), tracking on, the camera watching; at each crossing a still
    /// frame and its sharp edge; then the circle of the Moon's radius
    /// through them. Nil (with a message) if it can't be trusted, for the
    /// survey to take over.
    func probeLimbCentre(radius r: Double) async throws -> MoonCentre.Fit? {
        guard let calibration, let here else { return nil }
        if (try? mount.status().state) == "Armed" { endStep() }
        try camera.configure(exposureUs: settings.exposureUs, gain: settings.gain)
        try camera.start()
        defer {
            camera.stop()
            let rate = moonRate(at: clock())
            try? mount.track(azDegS: rate.az, altDegS: rate.alt)
        }
        let origin = (here.time, [here.azimuthDeg, here.altitudeDeg])
        /// Where the camera points now, against Here (″), from the mount.
        func pointing(at frameTime: Date? = nil) async throws -> SkyOffset {
            let read = try await readAfter(Date().addingTimeInterval(-0.3), limit: 2)
            var p = read.p
            let r = (try? mount.status().tracking) ?? nil ?? [0, 0]
            let target = frameTime ?? Date()
            let ahead = target.timeIntervalSince(read.wall)
            p = [p[0] + r[0] * ahead, p[1] + r[1] * ahead]
            return relativeMove(from: origin, to: (clock().addingTimeInterval(target.timeIntervalSinceNow), p))
        }
        let start = try await pointing()
        let phase = Ephemeris.phase(at: clock(), from: settings.site)
        let base = atan2(phase.brightLimb.x, phase.brightLimb.y)
        let turns: [Double] = phase.phaseAngleDeg > 15 ? [0, -65, 65] : [0, 120, 240]
        let fieldHeight = Double(min(camera.info.width, camera.info.height)) * calibration.arcsecPerPixel
        let length = 2 * r + fieldHeight
        let speed = 0.15  // °/s on the sky: 7″ a frame at 75 fps
        let daytime = sunHorizontal(at: clock()).altDeg > SunGuard.upAltitudeDeg
        var all: [LimbEdge.Point] = []
        var guesses: [SkyOffset] = []
        var found = 0
        let stamp = Self.fileStamp(clock())
        for (k, turn) in turns.enumerated() {
            let t = base + turn * .pi / 180
            let e = SkyOffset(x: sin(t), y: cos(t))
            onEvent(.detail("Limb probe \(k + 1) of \(turns.count): out across the limb"))
            try await rateMove(to: try target(start, at: clock()), speedDegS: 1.5)
            try await Task.sleep(for: .milliseconds(300))
            let first = try await grabFrame()
            let ref = first.pixels.enumerated().filter { $0.offset % 7 == 0 }.map { Int($0.element) }.sorted()
            let top = Double(ref[ref.count * 9 / 10])
            let threshold = (daytime ? 0.8 : 0.5) * top
            func litShare(_ f: Frame) -> Double {
                var n = 0
                var lit = 0
                var i = 0
                while i < f.pixels.count {
                    if Double(f.pixels[i]) >= threshold { lit += 1 }
                    n += 1
                    i += 11
                }
                return Double(lit) / Double(max(1, n))
            }
            guard litShare(first) > 0.3 else {
                onEvent(.message("Limb probe: Here isn't on the bright Moon (the frame is mostly dark); using the survey."))
                return nil
            }
            // Out along e, tracking on, watching.
            let alt = Self.moonAxes(at: clock(), settings.site).alt
            let cosAlt = cos(alt * .pi / 180)
            let seconds = length / 3600 / speed
            let rate = moonRate(at: clock())
            let (rAz, rAlt) = (e.x * speed / cosAlt, e.y * speed)
            try checkSun(
                from: try { let a = try target(start, at: clock()); return [a.az, a.alt] }(),
                to: try {
                    let b = try target(SkyOffset(x: start.x + e.x * length, y: start.y + e.y * length), at: clock())
                    return [b.az, b.alt]
                }(), what: "the limb probe")
            try mount.track(azDegS: rate.az + rAz, altDegS: rate.alt + rAlt)
            let wall0 = Date()
            var lastLit: (Date, Double)?
            var firstDark: (Date, Double)?
            var darkRun = 0
            while Date().timeIntervalSince(wall0) < seconds {
                guard let f = try camera.frame(timeoutMs: 500) else { continue }
                let share = litShare(f)
                if share >= 0.3 {
                    lastLit = (f.time, share)
                    darkRun = 0
                    firstDark = nil
                } else if lastLit != nil {
                    if firstDark == nil { firstDark = (f.time, share) }
                    darkRun += 1
                    if darkRun >= 4 { break }
                }
            }
            let stopped = Date()
            try mount.track(azDegS: rate.az, altDegS: rate.alt)
            guard let lit = lastLit, let dark = firstDark else {
                onEvent(.message(String(format: "Limb probe %d: no limb crossed within %.0f″.", k + 1, length)))
                continue
            }
            // The crossing: between the last lit frame and the first dark
            // one, along the line from where it started.
            let mid = lit.0.addingTimeInterval(dark.0.timeIntervalSince(lit.0) / 2)
            let along = speed * 3600 * max(0, mid.timeIntervalSince(wall0))
            _ = stopped
            let crossing = SkyOffset(x: start.x + e.x * along, y: start.y + e.y * along)
            // Back to it, the limb mid-frame, still; then its edge.
            try await rateMove(to: try target(crossing, at: clock()), speedDegS: 1.0, toleranceDeg: 0.01)
            try await Task.sleep(for: .milliseconds(Int(max(300, settings.settleSeconds * 700))))
            var points: [LimbEdge.Point] = []
            for n in 0..<3 {
                let f = try await grabFrame()
                let p = try await pointing(at: f.time)
                let pts = LimbEdge.points(f, pointing: p, calibration: calibration, outward: e)
                points += pts
                if n == 0 { keep([("\(stamp)-limb\(k)", f)], in: "limb") }
            }
            guard points.count >= 30 else {
                onEvent(.message("Limb probe \(k + 1): the limb wasn't sharp in view (\(points.count) edge points)."))
                continue
            }
            found += 1
            all += points
            guesses.append(SkyOffset(x: crossing.x - e.x * r, y: crossing.y - e.y * r))
            note(
                "limb",
                [
                    "time": stamp, "probe": k, "direction": [e.x, e.y], "crossing": [crossing.x, crossing.y],
                    "points": points.count,
                ])
        }
        onEvent(.detail(nil))
        guard found >= 2, !guesses.isEmpty else {
            onEvent(.message("Limb probe: only \(found) of \(turns.count) limbs found; using the survey."))
            return nil
        }
        let start0 = SkyOffset(
            x: guesses.map(\.x).reduce(0, +) / Double(guesses.count),
            y: guesses.map(\.y).reduce(0, +) / Double(guesses.count))
        guard let circle = LimbEdge.fit(all, radius: r, start: start0) else {
            onEvent(.message("Limb probe: no circle fitted the edges; using the survey."))
            return nil
        }
        let share = Double(circle.inliers) / Double(circle.total)
        let radiusOff = circle.freeRadius / r - 1
        note(
            "limb",
            [
                "time": stamp, "kind": "fit", "centre": [circle.centre.x, circle.centre.y], "radius": r,
                "freeRadius": circle.freeRadius, "inliers": circle.inliers, "points": circle.total, "rms": circle.rms,
                "probes": found,
            ])
        onEvent(
            .message(
                String(
                    format: "Limb probe: %d limbs, %d of %d edge points on the circle (±%.1f″); free radius %.0f″ against %.0f″ (%+.1f%%).",
                    found, circle.inliers, circle.total, circle.rms, circle.freeRadius, r, radiusOff * 100)))
        guard abs(radiusOff) < 0.04, share > 0.3 else {
            onEvent(.message("Limb probe: the circle doesn't check out; using the survey."))
            return nil
        }
        return MoonCentre.Fit(
            centre: circle.centre, agreement: share, moonCells: 0, litCells: circle.inliers, skyCells: 0,
            // Not measured by the probe: at night the dark side's earthshine
            // is there to capture (the dark tiles stay in the plan); by day
            // it never shows.
            earthshine: !daytime, levels: MoonCentre.Levels(sky: 0, moon: 0, lit: 0))
    }
}
