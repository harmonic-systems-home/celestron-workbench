import Accelerate
import Foundation

/// The shift between two frames by phase correlation (ADR 0019, as in O17):
/// frames binned 2×2 (which also removes the Bayer pattern), a central
/// power-of-two square windowed, a band-pass keeping structure of about
/// 8–200 binned pixels (pixel-level fixed pattern and vignetting don't move
/// with the scene and would pin the peak at zero), and a parabolic fit
/// around the peak for sub-pixel precision. A second pass moves `b`'s crop
/// by the first estimate, so both crops show the same scene: with only part
/// of it shared, the fit is pulled towards zero (about a pixel in 50).
public enum Registration {
    /// How far `b`'s content has moved from `a`'s, in full-resolution pixels
    /// (x right, y down), and the peak's strength (0–1; low means unreliable).
    /// With `minShift` (full-resolution pixels), peaks nearer zero than that
    /// are ignored in the first pass: for a scene known to have moved (the
    /// Moon drifting), the sensor's fixed pattern can't win (2026-11-19).
    public static func shift(
        from a: Frame, to b: Frame, minShift: Double = 0
    ) -> (dx: Double, dy: Double, peak: Double) {
        precondition(a.width == b.width && a.height == b.height, "frames differ in size")
        let (w, h) = (a.width / 2, a.height / 2)
        var n = 1
        while n * 2 <= min(w, h) && n < 512 { n *= 2 }
        let log2n = vDSP_Length(n.trailingZeroBitCount)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else {
            return (0, 0, 0)
        }
        defer { vDSP_destroy_fftsetup(setup) }

        let window = hann(n)
        let fa = spectrum(a, n: n, window: window, setup: setup, log2n: log2n, offset: (0, 0))
        let first = correlate(
            fa, spectrum(b, n: n, window: window, setup: setup, log2n: log2n, offset: (0, 0)),
            n: n, setup: setup, log2n: log2n, exclude: minShift / 2)
        // b's content moved by (dx, dy) binned pixels: crop b there too (as
        // far as the frame allows; the crop reports where it actually was).
        let offset = (Int(first.dx.rounded()), Int(first.dy.rounded()))
        let fb = spectrum(b, n: n, window: window, setup: setup, log2n: log2n, offset: offset)
        // Once aligned, the true peak is near zero; the fixed pattern would
        // sit at minus the offset, so only a small window is searched.
        // When the frame's edge stopped the crop short of the first estimate,
        // what's left of the shift isn't near zero: search around it
        // (2026-11-20: a 512-high crop in a 540-high binned frame has only
        // ±14 binned pixels to move, so most vertical shifts were clipped and
        // the window around zero held no peak).
        let residual = (first.dx - Double(fb.used.0), first.dy - Double(fb.used.1))
        let second = correlate(
            fa, fb, n: n, setup: setup, log2n: log2n,
            within: minShift > 0 ? max(4, minShift / 4) : nil, around: residual)
        return (
            2 * (Double(fb.used.0) + second.dx), 2 * (Double(fb.used.1) + second.dy), second.peak
        )
    }

    /// The shift (binned pixels) from `fa`'s crop to `fb`'s.
    private static func correlate(
        _ fa: (re: [Float], im: [Float], used: (Int, Int)),
        _ fb: (re: [Float], im: [Float], used: (Int, Int)), n: Int,
        setup: FFTSetup, log2n: vDSP_Length, exclude: Double = 0, within: Double? = nil,
        around: (Double, Double) = (0, 0)
    ) -> (dx: Double, dy: Double, peak: Double) {
        // Normalized cross-power with the band-pass applied.
        var real = [Float](repeating: 0, count: n * n)
        var imag = [Float](repeating: 0, count: n * n)
        for y in 0..<n {
            let fy = Float(y < n / 2 ? y : y - n) / Float(n)
            for x in 0..<n {
                let fx = Float(x < n / 2 ? x : x - n) / Float(n)
                let f = (fx * fx + fy * fy).squareRoot()
                let band = exp(-(f / 0.06) * (f / 0.06)) * (1 - exp(-(f / 0.005) * (f / 0.005)))
                let i = y * n + x
                // a · conj(b)
                let re = fa.re[i] * fb.re[i] + fa.im[i] * fb.im[i]
                let im = fa.im[i] * fb.re[i] - fa.re[i] * fb.im[i]
                let mag = (re * re + im * im).squareRoot() + 1e-12
                real[i] = re / mag * band
                imag[i] = im / mag * band
            }
        }
        real.withUnsafeMutableBufferPointer { r in
            imag.withUnsafeMutableBufferPointer { m in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                vDSP_fft2d_zip(
                    setup, &split, 1, 0, log2n, log2n, FFTDirection(kFFTDirection_Inverse))
            }
        }
        func allowed(_ i: Int) -> Bool {
            let (y, x) = (i / n, i % n)
            let dy = Double(y < n / 2 ? y : y - n)
            let dx = Double(x < n / 2 ? x : x - n)
            let r = (dx * dx + dy * dy).squareRoot()
            // The peak sits at minus the shift (a·conj(b)).
            let near = hypot(dx + around.0, dy + around.1)
            return r >= exclude && (within.map { near <= $0 } ?? true)
        }
        var best = -1
        for i in 0..<(n * n) where allowed(i) && (best < 0 || real[i] > real[best]) { best = i }
        if best < 0 { best = 0 }
        let (py, px) = (best / n, best % n)
        let at = { (y: Int, x: Int) in Double(real[((y + n) % n) * n + (x + n) % n]) }
        func refine(_ m: Double, _ z: Double, _ p: Double) -> Double {
            let d = m - 2 * z + p
            return d == 0 ? 0 : (m - p) / (2 * d)
        }
        let z = at(py, px)
        var sx = Double(px) + refine(at(py, px - 1), z, at(py, px + 1))
        var sy = Double(py) + refine(at(py - 1, px), z, at(py + 1, px))
        if sx > Double(n) / 2 { sx -= Double(n) }
        if sy > Double(n) / 2 { sy -= Double(n) }
        let total = real.reduce(0) { $0 + abs($1) }
        // a·conj(b) peaks at a's offset from b: b moved by minus that.
        return (-sx, -sy, total > 0 ? Double(z) / Double(total) * Double(n) : 0)
    }

    private static func hann(_ n: Int) -> [Float] {
        (0..<n).map { 0.5 - 0.5 * cos(2 * .pi * Float($0) / Float(n - 1)) }
    }

    /// An n×n crop of the 2×2-binned frame, centred plus `offset` (binned
    /// pixels, kept inside the frame), windowed and transformed.
    private static func spectrum(
        _ frame: Frame, n: Int, window: [Float], setup: FFTSetup, log2n: vDSP_Length,
        offset: (Int, Int)
    ) -> (re: [Float], im: [Float], used: (Int, Int)) {
        let (w, h) = (frame.width / 2, frame.height / 2)
        let x0 = min(max((w - n) / 2 + offset.0, 0), w - n)
        let y0 = min(max((h - n) / 2 + offset.1, 0), h - n)
        var re = [Float](repeating: 0, count: n * n)
        var im = [Float](repeating: 0, count: n * n)
        var sum: Float = 0
        frame.pixels.withUnsafeBufferPointer { p in
            for y in 0..<n {
                let row = 2 * (y0 + y) * frame.width
                for x in 0..<n {
                    let c = 2 * (x0 + x)
                    let v =
                        Float(p[row + c]) + Float(p[row + c + 1]) + Float(p[row + frame.width + c])
                        + Float(p[row + frame.width + c + 1])
                    re[y * n + x] = v
                    sum += v
                }
            }
        }
        let mean = sum / Float(n * n)
        for y in 0..<n {
            for x in 0..<n {
                re[y * n + x] = (re[y * n + x] - mean) * window[y] * window[x]
            }
        }
        re.withUnsafeMutableBufferPointer { r in
            im.withUnsafeMutableBufferPointer { m in
                var split = DSPSplitComplex(realp: r.baseAddress!, imagp: m.baseAddress!)
                vDSP_fft2d_zip(
                    setup, &split, 1, 0, log2n, log2n, FFTDirection(kFFTDirection_Forward))
            }
        }
        return (re, im, (x0 - (w - n) / 2, y0 - (h - n) / 2))
    }
}
