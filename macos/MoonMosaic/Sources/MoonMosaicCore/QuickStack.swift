import Foundation

/// A quick lucky-imaging stack for the field preview (ADR 0019): keeps the
/// sharpest few frames (by gradient energy at 4× binning) and averages them
/// after aligning each to the sharpest, at 4× binning.
public struct QuickStack: Sendable {
    public let keep: Int
    private(set) var frames: [(sharpness: Double, frame: Frame)] = []

    public init(keep: Int) {
        self.keep = keep
    }

    public var bestSharpness: Double { frames.first?.sharpness ?? 0 }

    public mutating func offer(_ frame: Frame) {
        let s = Self.sharpness(frame)
        guard frames.count < keep || s > (frames.last?.sharpness ?? 0) else { return }
        frames.append((s, frame))
        frames.sort { $0.sharpness > $1.sharpness }
        if frames.count > keep { frames.removeLast() }
    }

    /// The stack at 4× binning: width, height, values 0–1.
    public func image() -> (width: Int, height: Int, pixels: [Float])? {
        guard let best = frames.first?.frame else { return nil }
        let (w, h) = (best.width / 4, best.height / 4)
        var sum = [Float](repeating: 0, count: w * h)
        var count = [Float](repeating: 0, count: w * h)
        for (_, frame) in frames {
            let s = Registration.shift(from: best, to: frame)
            // This frame's content sits (dx, dy) from the best's: sample there.
            let (ox, oy) = (Int((s.dx / 4).rounded()), Int((s.dy / 4).rounded()))
            let binned = Self.bin4(frame)
            for y in 0..<h {
                let sy = y + oy
                guard sy >= 0, sy < h else { continue }
                for x in 0..<w {
                    let sx = x + ox
                    guard sx >= 0, sx < w else { continue }
                    sum[y * w + x] += binned[sy * w + sx]
                    count[y * w + x] += 1
                }
            }
        }
        return (w, h, zip(sum, count).map { $1 > 0 ? $0 / $1 : 0 })
    }

    static func bin4(_ f: Frame) -> [Float] {
        let (w, h) = (f.width / 4, f.height / 4)
        var out = [Float](repeating: 0, count: w * h)
        f.pixels.withUnsafeBufferPointer { p in
            for y in 0..<h {
                for x in 0..<w {
                    var s = 0
                    for dy in 0..<4 {
                        let row = (4 * y + dy) * f.width + 4 * x
                        s += Int(p[row]) + Int(p[row + 1]) + Int(p[row + 2]) + Int(p[row + 3])
                    }
                    out[y * w + x] = Float(s) / (16 * 255)
                }
            }
        }
        return out
    }

    static func sharpness(_ f: Frame) -> Double {
        let b = bin4(f)
        let (w, h) = (f.width / 4, f.height / 4)
        var e: Double = 0
        for y in 1..<max(h - 1, 1) {
            for x in 1..<max(w - 1, 1) {
                let gx = Double(b[y * w + x + 1] - b[y * w + x - 1])
                let gy = Double(b[(y + 1) * w + x] - b[(y - 1) * w + x])
                e += gx * gx + gy * gy
            }
        }
        return e / Double(max(w * h, 1))
    }
}
