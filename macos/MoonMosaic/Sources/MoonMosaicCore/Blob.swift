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
