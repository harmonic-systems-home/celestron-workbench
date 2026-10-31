import Foundation

/// Focusing (ADR 0019): the frame's middle at full resolution, and a number
/// that rises as the focus improves.
public enum Focus {
    /// The middle `fraction` of the frame (on each side), every pixel. Its
    /// origin is kept even, so a colour camera's Bayer pattern is unchanged.
    public static func crop(_ f: Frame, fraction: Double = 1.0 / 3) -> Frame {
        let w = Int(Double(f.width) * fraction) & ~1
        let h = Int(Double(f.height) * fraction) & ~1
        let x0 = ((f.width - w) / 2) & ~1
        let y0 = ((f.height - h) / 2) & ~1
        var out = [UInt8](repeating: 0, count: w * h)
        f.pixels.withUnsafeBufferPointer { p in
            for y in 0..<h {
                let row = (y0 + y) * f.width + x0
                for x in 0..<w { out[y * w + x] = p[row + x] }
            }
        }
        return Frame(width: w, height: h, pixels: out, time: f.time)
    }

    /// Mean squared difference between pixels two apart (the same colour on
    /// a Bayer sensor), over the lit part: dark sky is left out, so the
    /// number doesn't change as the Moon drifts across the frame's edge.
    public static func sharpness(_ f: Frame) -> Double {
        var e: Double = 0
        var n = 0
        f.pixels.withUnsafeBufferPointer { p in
            for y in 0..<max(f.height - 2, 0) {
                for x in 0..<max(f.width - 2, 0) {
                    let i = y * f.width + x
                    guard p[i] > 25 else { continue }
                    let gx = Double(p[i + 2]) - Double(p[i])
                    let gy = Double(p[i + 2 * f.width]) - Double(p[i])
                    e += gx * gx + gy * gy
                    n += 1
                }
            }
        }
        return n > 0 ? e / Double(n) : 0
    }
}
