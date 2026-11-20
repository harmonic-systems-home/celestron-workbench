import Foundation

/// The bright blob in a frame (ADR 0022). The Moon is by far the brightest
/// thing in view, in or out of focus, so its **intensity-weighted centroid**
/// locates it without any sharp features — which is why acquisition,
/// orientation and tracking all work on an out-of-focus Moon. This is
/// deliberately simple and allocation-light: one pass for the peak, one for
/// the weighted centroid of pixels above a fraction of that peak.
public enum Blob {
    public struct Found: Sendable, Equatable {
        /// Centroid in pixels from the top-left: x right, y down.
        public let x: Double
        public let y: Double
        /// Centroid relative to the frame centre, in pixels (x right, y down):
        /// what tracking drives to zero.
        public let offsetFromCentre: PixelOffset
        /// Brightest pixel in the frame, 0–255.
        public let peak: Int
        /// Mean level of the pixels that counted (above the threshold).
        public let meanAbove: Double
        /// Count of pixels above the threshold.
        public let pixels: Int
        /// Those pixels as a fraction of the frame: tiny = a small bright
        /// spot, large = the Moon fills the field (or the frame is saturated).
        public let brightFraction: Double
        /// The sky's level (the frame's 20th percentile), and the share of
        /// the frame clearly above it (by 20 counts): lit Moon however dim,
        /// near the terminator too, where a threshold set by a bright
        /// crater misses it (2026-11-20).
        public var background: Int = 0
        /// The brightest 2×2 mean (hot pixels don't reach it).
        public var smoothPeak: Int = 0
        public var litAboveSky: Double = 0
        /// The frame's 256-level histogram.
        public var histogram: [Int] = []
    }

    /// The blob above `thresholdFraction` of the peak, or nil if nothing is
    /// bright enough. `minPeak` rejects a frame that is all sky or noise (no
    /// pixel reaches it); `minPixels` rejects a lone hot pixel.
    ///
    /// `thresholdFraction` near 0.5 follows the bright disk well even when it
    /// saturates; lower it to pull in a faint, out-of-focus blob.
    public static func find(
        _ frame: Frame,
        thresholdFraction: Double = 0.5,
        minPeak: Int = 32,
        minPixels: Int = 16
    ) -> Found? {
        let px = frame.pixels
        guard !px.isEmpty, frame.width > 0, frame.height > 0 else { return nil }

        var peak: UInt8 = 0
        for p in px where p > peak { peak = p }
        guard Int(peak) >= minPeak else { return nil }
        // The sky, the lit share and the histogram from 2×2 means: a colour
        // sensor's raw frame of a blue sky has bright blue and dark red
        // pixels side by side, and noise and hot pixels shrink too, so a
        // bright, plain sky no longer reads as half lit (2026-11-20,
        // simulator: a daytime sky passed as the Moon). The Moon is far
        // bigger than 2×2, so it is unchanged.
        var hist = [Int](repeating: 0, count: 256)
        var binnedPeak = 0
        let (bw, bh) = (frame.width / 2, frame.height / 2)
        if bw > 0, bh > 0 {
            for y in 0..<bh {
                let r0 = 2 * y * frame.width, r1 = r0 + frame.width
                for x in 0..<bw {
                    let v = (Int(px[r0 + 2 * x]) + Int(px[r0 + 2 * x + 1]) + Int(px[r1 + 2 * x]) + Int(px[r1 + 2 * x + 1]) + 2) / 4
                    hist[v] += 1
                    if v > binnedPeak { binnedPeak = v }
                }
            }
        } else {
            for p in px { hist[Int(p)] += 1 }
        }
        let cells = max(1, hist.reduce(0, +))
        var background = 0
        var seen = 0
        for (v, c) in hist.enumerated() {
            seen += c
            if seen * 5 >= cells {
                background = v
                break
            }
        }
        let litLevel = min(255, background + 20)
        let litCount = hist[litLevel...].reduce(0, +)

        let threshold = UInt8(max(1, min(255, Int((Double(peak) * thresholdFraction).rounded()))))
        let w = frame.width
        var sumW = 0.0
        var sumX = 0.0
        var sumY = 0.0
        var count = 0
        var i = 0
        for y in 0..<frame.height {
            for x in 0..<w {
                let v = px[i]
                i += 1
                if v >= threshold {
                    let wv = Double(v)
                    sumW += wv
                    sumX += wv * Double(x)
                    sumY += wv * Double(y)
                    count += 1
                }
            }
        }
        guard count >= minPixels, sumW > 0 else { return nil }

        let cx = sumX / sumW
        let cy = sumY / sumW
        return Found(
            x: cx,
            y: cy,
            offsetFromCentre: PixelOffset(
                x: cx - Double(frame.width) / 2, y: cy - Double(frame.height) / 2),
            peak: Int(peak),
            meanAbove: sumW / Double(count),
            pixels: count,
            brightFraction: Double(count) / Double(px.count),
            background: background,
            smoothPeak: binnedPeak,
            litAboveSky: Double(litCount) / Double(cells),
            histogram: hist
        )
    }
}

extension Blob {
    /// The sky the search looks against: each has its own trigger.
    public enum Sky: String, CaseIterable, Sendable {
        /// Dark sky: the Moon stands far above it.
        case clearNight
        /// Haze or thin cloud: lower contrast, a glow around the Moon.
        case cloudyNight
        /// Daylight: a bright sky, and the Moon only somewhat brighter.
        case day

        /// How far above the sky the peak must be, how far above the sky a
        /// pixel counts as lit, and the share of the frame that must be lit.
        public var trigger: (peak: Int, lit: Int, share: Double) {
            switch self {
            case .clearNight: (40, 20, 0.03)
            case .cloudyNight: (20, 10, 0.03)
            case .day: (15, 10, 0.05)
            }
        }
    }

    /// The search's test for "the Moon is in view": a peak well above the
    /// sky and enough of the frame clearly above it. 2026-11-20 (simulator,
    /// real images): near the terminator the lit area is dim beside a few
    /// bright crater rims, so a threshold set by the peak missed it; hot
    /// pixels alone are far fewer than 3%.
    public static func looksLikeMoon(_ b: Found?, sky: Sky = .clearNight) -> Bool {
        guard let b else { return false }
        let t = sky.trigger
        let share = t.lit == 20 ? b.litAboveSky : b.litAbove(t.lit)
        let peak = b.smoothPeak > 0 ? b.smoothPeak : b.peak
        return peak >= b.background + t.peak && share >= t.share
    }
}

extension Blob.Found {
    /// The share of the frame more than `counts` above the sky.
    public func litAbove(_ counts: Int) -> Double {
        guard counts != 20 else { return litAboveSky }
        let level = min(255, background + counts)
        let n = histogram.reduce(0, +)
        return n > 0 ? Double(histogram[level...].reduce(0, +)) / Double(n) : 0
    }
}

/// Brightness numbers for the live view (ADR 0022 amendment 7's Light
/// readout): what the search's detector sees, and how the exposure sits.
public struct FrameStats: Sendable, Equatable {
    public let peak: Int
    public let mean: Double
    /// Share of pixels at 255 (clipped), and lit by the detector's rule.
    public let clipped: Double
    public let lit: Double
    public let moonInView: Bool
    public let background: Int
    public let skyName: String
    /// 64-bin histogram, each bin's share of the pixels.
    public let histogram: [Double]

    public init(_ f: Frame, sky: Blob.Sky = .clearNight) {
        var hist = [Int](repeating: 0, count: 64)
        var sum = 0
        var top: UInt8 = 0
        var full = 0
        for p in f.pixels {
            hist[Int(p) >> 2] += 1
            sum += Int(p)
            if p > top { top = p }
            if p == 255 { full += 1 }
        }
        let n = Double(max(f.pixels.count, 1))
        let blob = Blob.find(f, thresholdFraction: 0.3)
        peak = Int(top)
        mean = Double(sum) / n
        clipped = Double(full) / n
        lit = blob.map { $0.litAbove(sky.trigger.lit) } ?? 0
        moonInView = Blob.looksLikeMoon(blob, sky: sky)
        background = blob?.background ?? 0
        skyName = ["clearNight": "clear-night", "cloudyNight": "cloudy-night", "day": "day"][sky.rawValue] ?? sky.rawValue
        histogram = hist.map { Double($0) / n }
    }
}
