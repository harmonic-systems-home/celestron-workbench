import Foundation

/// Finding the Moon's centre from a survey (ADR 0019, amendment 1): the
/// camera sees only a small part of the Moon, so its centre can't be judged
/// by eye. Frames taken on a grid around *Here*, at a long exposure, are cut
/// into cells; each cell is Moon (above the sky) or sky, and lit (sunlit) or
/// not. A circle of the Moon's known radius is then fitted to the cells.
///
/// With earthshine above the sky the whole disk counts as Moon, at any
/// phase. Without it the dark side counts as sky, and the fit rests on the
/// lit part: lit cells can't lie outside the disk (a strong penalty), and
/// sky cells inside it (the dark side) are only weakly penalised. The
/// crescent's outer edge is itself an arc of the Moon's radius, so it pins
/// the circle.
public enum MoonCentre {
    /// One cell of a survey frame: where it is on the sky, in arcseconds
    /// from *Here*'s centre (the same frame as `SkyOffset`), and its mean.
    public struct Sample: Sendable, Equatable {
        public let sky: SkyOffset
        public let mean: Double

        public init(sky: SkyOffset, mean: Double) {
            self.sky = sky
            self.mean = mean
        }
    }

    public struct Levels: Sendable, Equatable {
        /// The sky's level, and the thresholds above it for Moon and for lit.
        public let sky: Double
        public let moon: Double
        public let lit: Double
    }

    public struct Fit: Sendable, Equatable {
        /// The Moon's centre, in arcseconds from where *Here* put it.
        public let centre: SkyOffset
        /// Cells agreeing with the circle, as a fraction of those that count.
        public let agreement: Double
        public let moonCells: Int
        public let litCells: Int
        public let skyCells: Int
        /// Whether cells inside the disk but off the lit part were mostly
        /// above the sky: earthshine seen.
        public let earthshine: Bool
        public let levels: Levels
    }

    /// Cells of `cellPixels` square, each with its sky position for a frame
    /// taken with the camera at `pointing` (relative to Here's centre). A
    /// part of the Moon at sky offset s appears at pixel −M·(s − pointing)
    /// from the frame's centre (M the calibration), so a cell at pixel u
    /// sees s = pointing − M⁻¹·u.
    public static func samples(
        _ frame: Frame, pointing: SkyOffset, calibration: CameraCalibration, cellPixels: Int = 80
    ) -> [Sample] {
        let (w, h) = (frame.width, frame.height)
        let cell = max(4, cellPixels)
        var out: [Sample] = []
        var y0 = (h % cell) / 2
        while y0 + cell <= h {
            var x0 = (w % cell) / 2
            while x0 + cell <= w {
                var sum = 0
                // Every other pixel each way: plenty for a mean.
                var n = 0
                for y in stride(from: y0, to: y0 + cell, by: 2) {
                    let row = y * w
                    for x in stride(from: x0, to: x0 + cell, by: 2) {
                        sum += Int(frame.pixels[row + x])
                        n += 1
                    }
                }
                let u = PixelOffset(
                    x: Double(x0) + Double(cell) / 2 - Double(w) / 2,
                    y: Double(y0) + Double(cell) / 2 - Double(h) / 2)
                let d = calibration.sky(for: u)
                out.append(
                    Sample(
                        sky: SkyOffset(x: pointing.x - d.x, y: pointing.y - d.y),
                        mean: Double(sum) / Double(n)))
                x0 += cell
            }
            y0 += cell
        }
        return out
    }

    /// The sky level is taken from the darkest fifth of the cells (the
    /// survey reaches well past the limb, so they are sky); Moon is
    /// anything clearly above it, and lit is over halfway from the sky to
    /// the brightest cells.
    public static func levels(_ samples: [Sample]) -> Levels {
        let means = samples.map(\.mean).sorted()
        guard !means.isEmpty else { return Levels(sky: 0, moon: 1, lit: 1) }
        let darkest = means.prefix(max(1, means.count / 5))
        let sky = darkest.reduce(0, +) / Double(darkest.count)
        let spread =
            (darkest.map { ($0 - sky) * ($0 - sky) }.reduce(0, +) / Double(darkest.count))
            .squareRoot()
        let top = means[min(means.count - 1, Int(Double(means.count) * 0.98))]
        let moon = sky + max(4, 5 * spread)
        let lit = max(moon, sky + 0.5 * (top - sky))
        return Levels(sky: sky, moon: moon, lit: lit)
    }

    /// The circle of `radiusArcsec` that best fits the cells, its centre
    /// searched within `searchArcsec` of Here's centre. Nil when the survey
    /// has no lit cells or no sky.
    ///
    /// With `phase` (and away from full), the fit matches the sunlit cells
    /// to the sunlit shape the ephemeris predicts (bright limb and
    /// terminator) instead: the Moon's glow outside the limb, bright at the
    /// survey's long exposure, then can't pass for Moon (2026-11-20, the test
    /// runner: glow cells pulled the circle outward and failed the fit).
    public static func fit(
        _ samples: [Sample], radiusArcsec r: Double, searchArcsec: Double, phase: Ephemeris.Phase? = nil
    ) -> Fit? {
        if let phase, phase.phaseAngleDeg > 15, phase.phaseAngleDeg < 165 {
            return fitLitShape(samples, radiusArcsec: r, searchArcsec: searchArcsec, phase: phase)
        }
        return fitDisk(samples, radiusArcsec: r, searchArcsec: searchArcsec)
    }

    static func fitLitShape(
        _ samples: [Sample], radiusArcsec r: Double, searchArcsec: Double, phase: Ephemeris.Phase
    ) -> Fit? {
        let lv = levels(samples)
        let pts = samples.map { (x: $0.sky.x, y: $0.sky.y, moon: $0.mean >= lv.moon, lit: $0.mean >= lv.lit) }
        let litCount = pts.filter(\.lit).count
        let moonCount = pts.filter(\.moon).count
        guard litCount > 0, pts.count - litCount > 0 else { return nil }
        let (lx, ly) = phase.brightLimb
        let c = cos(phase.phaseAngleDeg * .pi / 180)
        let edge = 15 / r
        /// +1 predicted lit, −1 predicted dark, 0 too near an edge to say.
        func predicted(_ x: Double, _ y: Double) -> Int {
            let (u, v) = (x / r, y / r)
            let d = (u * u + v * v).squareRoot()
            if abs(d - 1) < edge { return 0 }
            if d > 1 { return -1 }
            let a = u * lx + v * ly
            let b = -u * ly + v * lx
            let t = -c * max(0, 1 - b * b).squareRoot()
            if abs(a - t) < 2 * edge { return 0 }
            return a > t ? 1 : -1
        }
        func score(_ cx: Double, _ cy: Double) -> Double {
            var s = 0.0
            for p in pts {
                switch (predicted(p.x - cx, p.y - cy), p.lit) {
                case (1, true): s += 1
                case (1, false): s -= 1
                case (-1, true): s -= 2
                case (-1, false): s += 0.3
                default: break
                }
            }
            return s
        }
        var best = (x: 0.0, y: 0.0, s: -Double.infinity)
        for step in [30.0, 6.0, 1.5] {
            let around = best.s.isFinite ? (best.x, best.y) : (0.0, 0.0)
            let reach = best.s.isFinite ? step * 6 : searchArcsec
            let n = Int((reach / step).rounded(.up))
            for i in -n...n {
                for j in -n...n {
                    let cx = around.0 + Double(i) * step
                    let cy = around.1 + Double(j) * step
                    guard cx * cx + cy * cy <= searchArcsec * searchArcsec else { continue }
                    let s = score(cx, cy)
                    if s > best.s { best = (cx, cy, s) }
                }
            }
        }
        // Agreement: of the cells predicted lit or seen lit, the share that
        // match. Earthshine: dark-side cells mostly above the sky.
        var (agree, counted, darkInside, earthshineInside) = (0, 0, 0, 0)
        for p in pts {
            let q = predicted(p.x - best.x, p.y - best.y)
            if q == 0 { continue }
            if q == 1 || p.lit {
                counted += 1
                if (q == 1) == p.lit { agree += 1 }
            }
            let inside = hypot(p.x - best.x, p.y - best.y) < r - 15
            if q == -1, inside, !p.lit {
                if p.moon { earthshineInside += 1 } else { darkInside += 1 }
            }
        }
        return Fit(
            centre: SkyOffset(x: best.x, y: best.y),
            agreement: counted > 0 ? Double(agree) / Double(counted) : 0,
            moonCells: moonCount, litCells: litCount, skyCells: pts.count - moonCount,
            earthshine: earthshineInside > darkInside, levels: lv)
    }

    /// The whole disk's circle (full Moon, or no phase given).
    static func fitDisk(
        _ samples: [Sample], radiusArcsec r: Double, searchArcsec: Double
    ) -> Fit? {
        let lv = levels(samples)
        let pts = samples.map { (x: $0.sky.x, y: $0.sky.y, moon: $0.mean >= lv.moon, lit: $0.mean >= lv.lit) }
        let litCount = pts.filter(\.lit).count
        let moonCount = pts.filter(\.moon).count
        let skyCount = pts.count - moonCount
        guard litCount > 0, skyCount > 0 else { return nil }
        // A cell straddling the limb may go either way: within this of the
        // edge it doesn't count.
        let r2 = r * r
        func score(_ cx: Double, _ cy: Double) -> Double {
            var s = 0.0
            let inner = (r - 15) * (r - 15)
            let outer = (r + 15) * (r + 15)
            for p in pts {
                let dx = p.x - cx
                let dy = p.y - cy
                let d2 = dx * dx + dy * dy
                if d2 > inner && d2 < outer { continue }
                let inside = d2 < r2
                if p.moon {
                    s += inside ? 1 : (p.lit ? -4 : -2)
                } else {
                    s += inside ? -0.3 : 1
                }
            }
            return s
        }
        var best = (x: 0.0, y: 0.0, s: -Double.infinity)
        for step in [30.0, 6.0, 1.5] {
            let around = best.s.isFinite ? (best.x, best.y) : (0.0, 0.0)
            let reach = best.s.isFinite ? step * 6 : searchArcsec
            let n = Int((reach / step).rounded(.up))
            for i in -n...n {
                for j in -n...n {
                    let cx = around.0 + Double(i) * step
                    let cy = around.1 + Double(j) * step
                    guard cx * cx + cy * cy <= searchArcsec * searchArcsec else { continue }
                    let s = score(cx, cy)
                    if s > best.s { best = (cx, cy, s) }
                }
            }
        }
        // How well the circle explains the cells: each cell that counts, as
        // the Moon (inside) or sky (outside); the dark side doesn't count
        // against it.
        var agree = 0
        var counted = 0
        var darkInside = 0
        var earthshineInside = 0
        for p in pts {
            let d = hypot(p.x - best.x, p.y - best.y)
            if abs(d - r) < 15 { continue }
            let inside = d < r
            if inside && !p.lit {
                if p.moon { earthshineInside += 1 } else { darkInside += 1 }
            }
            if inside && !p.moon { continue }
            counted += 1
            if inside == p.moon { agree += 1 }
        }
        return Fit(
            centre: SkyOffset(x: best.x, y: best.y),
            agreement: counted > 0 ? Double(agree) / Double(counted) : 0,
            moonCells: moonCount, litCells: litCount, skyCells: skyCount,
            earthshine: earthshineInside > darkInside, levels: lv)
    }
}
