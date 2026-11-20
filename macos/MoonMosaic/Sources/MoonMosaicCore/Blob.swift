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
            brightFraction: Double(count) / Double(px.count)
        )
    }
}

extension Blob {
    /// The search's test for "the Moon is in view" (night): a clear peak and
    /// enough of the frame lit, counting pixels above 30% of the peak.
    /// 2026-11-20 (simulator, a real gibbous image): frames near the
    /// terminator peak at only ~100 with 5–15% lit; hot pixels alone give a
    /// peak of ~70 with nothing lit.
    public static func looksLikeMoon(_ b: Found?) -> Bool {
        (b?.peak ?? 0) >= 60 && (b?.brightFraction ?? 0) >= 0.05
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
    /// 64-bin histogram, each bin's share of the pixels.
    public let histogram: [Double]

    public init(_ f: Frame) {
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
        lit = blob?.brightFraction ?? 0
        moonInView = Blob.looksLikeMoon(blob)
        histogram = hist.map { Double($0) / n }
    }
}
