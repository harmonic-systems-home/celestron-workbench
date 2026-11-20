import Foundation

/// Auto-set (ADR 0022 amendment 7, step 4): exposure and gain from a frame
/// of the Moon. The brightest lit area sits just below clipping (well under
/// 0.1% of pixels at 255), with the shortest exposure that allows it, to
/// freeze the seeing, and gain making up the rest. ZWO gain is in 0.1 dB,
/// so brightness goes as exposure × 10^(gain/200).
public enum AutoExposure {
    public struct Limits: Sendable {
        /// The shortest exposure worth using, and the longest the seeing allows.
        public var minExposureUs = 500
        public var maxExposureUs = 20_000
        /// Above this the noise grows faster than the signal is worth.
        public var maxGain = 300
        public var minGain = 0
        /// Where the bright end (the 99.9th percentile) should sit, 0–255.
        public var target = 215.0
        public init() {}
    }

    public struct Suggestion: Sendable, Equatable {
        public let exposureUs: Int
        public let gain: Int
        /// The bright end now (99.9th percentile), and the share clipped.
        public let brightLevel: Double
        public let clipped: Double
        /// Close enough: the bright end within 8% of the target, little clipped.
        public let settled: Bool
    }

    /// The 99.9th percentile level of a frame, and the share at 255.
    public static func brightEnd(_ f: Frame) -> (level: Double, clipped: Double) {
        var hist = [Int](repeating: 0, count: 256)
        for p in f.pixels { hist[Int(p)] += 1 }
        let n = max(f.pixels.count, 1)
        let clipped = Double(hist[255]) / Double(n)
        var above = 0
        var level = 0
        for v in stride(from: 255, through: 0, by: -1) {
            above += hist[v]
            if Double(above) >= 0.001 * Double(n) {
                level = v
                break
            }
        }
        return (Double(level), clipped)
    }

    /// The next exposure and gain from a frame taken at `exposureUs`, `gain`.
    public static func suggest(_ f: Frame, exposureUs: Int, gain: Int, limits l: Limits = Limits()) -> Suggestion {
        let (level, clipped) = brightEnd(f)
        // Clipped: how far over is unknown, so down by more the more is
        // clipped; nearly black: up 8×.
        let factor: Double
        if clipped > 0.1 {
            factor = 0.125
        } else if clipped > 0.01 {
            factor = 0.25
        } else if clipped > 0.001 || level >= 254 {
            factor = 0.5
        } else if level < 4 {
            factor = 8
        } else {
            factor = min(8, l.target / level)
        }
        let settled = clipped <= 0.001 && level < 254 && abs(level / l.target - 1) < 0.08
        // The brightness wanted, in microseconds at gain 0.
        let want = Double(exposureUs) * pow(10, Double(gain) / 200) * factor
        // Shortest exposure: as much gain as allowed, then exposure for the rest.
        var exposure = want / pow(10, Double(l.maxGain) / 200)
        exposure = min(max(exposure, Double(l.minExposureUs)), Double(l.maxExposureUs))
        var g = 200 * log10(want / exposure)
        g = min(max(g, Double(l.minGain)), Double(l.maxGain))
        return Suggestion(
            exposureUs: Int(exposure.rounded()), gain: Int(g.rounded()), brightLevel: level, clipped: clipped,
            settled: settled)
    }
}

extension MosaicSession {
    /// Auto-set: frames at the current settings, adjusted until the bright
    /// end sits just below clipping (up to eight tries). Leaves the camera
    /// settings on the result.
    @discardableResult
    public func autoExposure(limits: AutoExposure.Limits = AutoExposure.Limits()) async throws -> AutoExposure.Suggestion {
        var (exposure, gain) = (settings.exposureUs, settings.gain)
        var last: AutoExposure.Suggestion?
        for attempt in 1...8 {
            try camera.configure(exposureUs: exposure, gain: gain)
            try camera.start()
            // A few frames for the new settings to take.
            var frame: Frame?
            for _ in 0..<4 { frame = try camera.frame(timeoutMs: 1000) ?? frame }
            camera.stop()
            guard let frame else { throw MosaicError(description: "Auto-set: no frames from the camera.") }
            let s = AutoExposure.suggest(frame, exposureUs: exposure, gain: gain, limits: limits)
            onEvent(
                .detail(
                    String(
                        format: "Auto-set %d: %.1f ms, gain %d → bright end %.0f of 255, %.2f%% clipped",
                        attempt, Double(exposure) / 1000, gain, s.brightLevel, s.clipped * 100)))
            last = s
            if s.settled { break }
            if s.exposureUs == exposure, s.gain == gain { break }
            (exposure, gain) = (s.exposureUs, s.gain)
        }
        onEvent(.detail(nil))
        setCamera(exposureUs: exposure, gain: gain)
        guard let last else { throw MosaicError(description: "Auto-set: no frames.") }
        onEvent(
            .message(
                String(
                    format: "Auto-set: %.2f ms at gain %d (bright end %.0f of 255, %.2f%% clipped)%@.",
                    Double(exposure) / 1000, gain, last.brightLevel, last.clipped * 100,
                    last.settled ? "" : "; not settled: check the frame has bright Moon in it")))
        return last
    }
}
