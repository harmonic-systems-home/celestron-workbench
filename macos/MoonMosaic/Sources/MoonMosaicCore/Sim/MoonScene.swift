import CoreGraphics
import Foundation
import ImageIO

/// A Moon image for the simulated camera (ADR 0022 amendment 7): brightness
/// (0–1, linear), the disk's centre and radius in its pixels, and where its
/// bright limb points. Prepared once from an image file (our mosaics, DWARF
/// stacks, downloads), or drawn synthetically for tests. Real images live in
/// the private data folder, never in the repo.
public final class MoonScene: @unchecked Sendable {
    public let name: String
    /// Levels of detail: level 0 is the image, each next level half the size.
    let levels: [Level]
    /// The disk's centre and radius, in level-0 pixels.
    public let centre: (x: Double, y: Double)
    public let radius: Double
    /// The bright limb's direction, degrees clockwise from the image's up.
    /// Nil near full, where there is none to measure.
    public let brightLimbDeg: Double?
    /// The lit fraction measured from the image (lit disk area / disk area).
    public let litFraction: Double
    /// Optional facts from a sidecar file (`<image>.json`): where it came
    /// from, its licence, when it was taken, and where lunar north points.
    public let info: Info

    public struct Info: Codable, Sendable, Equatable {
        public var source: String?
        public var licence: String?
        public var taken: Date?
        /// Lunar north, degrees clockwise from the image's up.
        public var northDeg: Double?
        /// Taken with the frame level (up is the zenith), as the DWARF does:
        /// with `taken`, the image is the sky at that moment and needs no turn.
        public var level: Bool?
        /// Where it was taken, if known (private data only; scenes in the
        /// repo carry whole degrees). Without it, the app's own site is used.
        public var latitude: Double?
        public var longitude: Double?
        public init(source: String? = nil, licence: String? = nil, taken: Date? = nil, northDeg: Double? = nil) {
            self.source = source
            self.licence = licence
            self.taken = taken
            self.northDeg = northDeg
        }

        /// Reads `<image>.json` beside an image, if there is one.
        public static func sidecar(for url: URL) -> Info? {
            guard let data = try? Data(contentsOf: url.appendingPathExtension("json")) else { return nil }
            let d = JSONDecoder()
            d.dateDecodingStrategy = .iso8601
            return try? d.decode(Info.self, from: data)
        }
    }

    struct Level {
        let width: Int
        let height: Int
        let pixels: [Float]
    }

    public var width: Int { levels[0].width }
    public var height: Int { levels[0].height }

    /// A scene from brightness values (row by row, 0–1). The disk is fitted
    /// unless `centre` and `radius` are given.
    public init(
        name: String, width: Int, height: Int, pixels: [Float],
        centre: (x: Double, y: Double)? = nil, radius: Double? = nil, info: Info = Info()
    ) {
        precondition(pixels.count == width * height, "pixel count doesn't match the size")
        self.name = name
        self.info = info
        var levels = [Level(width: width, height: height, pixels: pixels)]
        while let last = levels.last, last.width >= 64, last.height >= 64 {
            levels.append(Self.halve(last))
        }
        self.levels = levels
        let fit = (centre != nil && radius != nil)
            ? (centre!, radius!) : Self.fitDisk(levels[0])
        self.centre = fit.0
        self.radius = fit.1
        let (limb, lit) = Self.measureLimb(levels[0], centre: fit.0, radius: fit.1)
        brightLimbDeg = limb
        litFraction = lit
    }

    /// Loads an image file (any format ImageIO reads), as grey brightness.
    /// A sidecar `<file>.json` (`Info`) is read if present.
    public convenience init(contentsOf url: URL) throws {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
        else { throw CameraError(description: "Can't read the image \(url.lastPathComponent).") }
        let (w, h) = (image.width, image.height)
        var grey = [UInt16](repeating: 0, count: w * h)
        let ok = grey.withUnsafeMutableBytes { buf -> Bool in
            guard
                let ctx = CGContext(
                    data: buf.baseAddress, width: w, height: h, bitsPerComponent: 16,
                    bytesPerRow: w * 2, space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                        | CGBitmapInfo.byteOrder16Little.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { throw CameraError(description: "Can't convert \(url.lastPathComponent).") }
        // Display values to linear light (an sRGB-like gamma), the brightest
        // part of the disk near 1.
        var pixels = grey.map { pow(Float($0) / 65535, 2.2) }
        let top = Self.percentile(pixels, 0.999)
        if top > 0 { pixels = pixels.map { min($0 / top, 1.5) } }
        let info = Info.sidecar(for: url) ?? Info()
        self.init(
            name: url.deletingPathExtension().lastPathComponent, width: w, height: h,
            pixels: pixels, info: info)
    }

    /// A synthetic Moon drawn by the fake camera: craters, maria and a
    /// terminator at the given phase angle (0 full, 90 half), lit from
    /// `brightLimbDeg` (clockwise from up). For tests and rehearsals without
    /// any image files.
    public static func synthetic(
        size: Int = 1024, phaseAngleDeg: Double = 60, brightLimbDeg: Double = 90, seed: UInt64 = 1
    ) -> MoonScene {
        let radiusArcsec = 930.0
        let scale = 2 * radiusArcsec / (Double(size) * 0.9)
        let fake = FakeCamera(
            width: size, height: size, scale: scale, rotationDeg: 0, moonRadiusArcsec: radiusArcsec,
            seed: seed)
        // The fake camera's Sun direction is from +x toward +y; limb angles
        // are clockwise from up.
        fake.sunDirectionDeg = 90 - brightLimbDeg
        fake.elongationDeg = 180 - phaseAngleDeg
        try? fake.configure(exposureUs: 2000, gain: 100)
        let f = try! fake.frame(timeoutMs: 0)!
        let pixels = f.pixels.map { Float($0) / 200 }
        return MoonScene(
            name: "synthetic-\(Int(phaseAngleDeg))", width: size, height: size, pixels: pixels,
            centre: (Double(size) / 2 + 0.5, Double(size) / 2 + 0.5), radius: radiusArcsec / scale)
    }

    // MARK: - Sampling

    /// Bilinear brightness at level-`level` pixel coordinates (0 off the image).
    @inline(__always)
    func sample(_ level: Int, _ x: Double, _ y: Double) -> Float {
        let l = levels[level]
        let fx = x - 0.5
        let fy = y - 0.5
        let x0 = Int(fx.rounded(.down))
        let y0 = Int(fy.rounded(.down))
        guard x0 >= 0, y0 >= 0, x0 + 1 < l.width, y0 + 1 < l.height else { return 0 }
        let ax = Float(fx - Double(x0))
        let ay = Float(fy - Double(y0))
        let i = y0 * l.width + x0
        return l.pixels.withUnsafeBufferPointer { p in
            let top = p[i] + (p[i + 1] - p[i]) * ax
            let bottom = p[i + l.width] + (p[i + l.width + 1] - p[i + l.width]) * ax
            return top + (bottom - top) * ay
        }
    }

    /// The level whose pixels are closest to (but no larger than) `step`
    /// level-0 pixels per output pixel.
    func level(forStep step: Double) -> Int {
        guard step > 1 else { return 0 }
        return min(Int(log2(step).rounded(.down)), levels.count - 1)
    }

    // MARK: - Preparation

    /// Lit means brighter than this fraction of the brightest (0.1% top)
    /// pixels, in linear light: maria are dark (a third or less of the
    /// brightest craters), so the threshold sits well below them, above the sky.
    static let litThreshold: Float = 0.05

    static func halve(_ l: Level) -> Level {
        let (w, h) = (l.width / 2, l.height / 2)
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = 2 * y * l.width + 2 * x
                out[y * w + x] =
                    (l.pixels[i] + l.pixels[i + 1] + l.pixels[i + l.width] + l.pixels[i + l.width + 1]) / 4
            }
        }
        return Level(width: w, height: h, pixels: out)
    }

    static func percentile(_ v: [Float], _ q: Double) -> Float {
        guard !v.isEmpty else { return 0 }
        // A histogram is plenty, and fast on large images.
        let bins = 4096
        let top = v.max() ?? 1
        guard top > 0 else { return 0 }
        var hist = [Int](repeating: 0, count: bins)
        for x in v { hist[min(bins - 1, Int(x / top * Float(bins - 1)))] += 1 }
        let target = Int(Double(v.count) * q)
        var n = 0
        for (i, c) in hist.enumerated() {
            n += c
            if n >= target { return top * Float(i) / Float(bins - 1) }
        }
        return top
    }

    /// The disk from its outer (lit, round) limb: the farthest lit pixel
    /// along rays from the lit centroid, the outer half of them, and a
    /// least-squares circle through those (as in the 2026-11-19 analysis).
    static func fitDisk(_ l: Level) -> ((x: Double, y: Double), Double) {
        // Fit on a small level for speed, then scale up.
        var small = l
        var factor = 1.0
        while small.width > 1200 {
            small = halve(small)
            factor *= 2
        }
        let thr = litThreshold * percentile(small.pixels, 0.999)
        var sx = 0.0, sy = 0.0, n = 0.0
        for y in 0..<small.height {
            for x in 0..<small.width where small.pixels[y * small.width + x] > thr {
                sx += Double(x)
                sy += Double(y)
                n += 1
            }
        }
        guard n > 0 else {
            return ((Double(l.width) / 2, Double(l.height) / 2), Double(min(l.width, l.height)) / 2)
        }
        let (cx0, cy0) = (sx / n, sy / n)
        var pts: [(Double, Double, Double)] = []
        let reach = Double(max(small.width, small.height))
        for k in 0..<360 {
            let a = Double(k) * .pi / 180
            var best: (Double, Double)?
            var r = 4.0
            while r < reach {
                let x = Int(cx0 + r * cos(a))
                let y = Int(cy0 + r * sin(a))
                guard x >= 0, y >= 0, x < small.width, y < small.height else { break }
                if small.pixels[y * small.width + x] > thr { best = (Double(x) + 0.5, Double(y) + 0.5) }
                r += 1
            }
            if let best { pts.append((best.0, best.1, hypot(best.0 - cx0, best.1 - cy0))) }
        }
        // The terminator and any dark limb lie inside the disk: fit, drop
        // the points well inside the circle, and fit again.
        var keep = pts.map { ($0.0, $0.1) }
        var fit = circle(keep)
        for _ in 0..<20 {
            let tol = max(1.0, 0.004 * fit.r)
            let next = keep.filter { hypot($0.0 - fit.cx, $0.1 - fit.cy) >= fit.r - tol }
            guard next.count >= 12, next.count < keep.count else { break }
            keep = next
            fit = circle(keep)
        }
        return ((fit.cx * factor, fit.cy * factor), fit.r * factor)
    }

    /// The least-squares circle through points: [2x 2y 1]·[cx cy c] = x²+y².
    static func circle(_ pts: [(Double, Double)]) -> (cx: Double, cy: Double, r: Double) {
        var ata = [[Double]](repeating: [0, 0, 0], count: 3)
        var atb = [0.0, 0.0, 0.0]
        for (x, y) in pts {
            let row = [2 * x, 2 * y, 1]
            let b = x * x + y * y
            for i in 0..<3 {
                for j in 0..<3 { ata[i][j] += row[i] * row[j] }
                atb[i] += row[i] * b
            }
        }
        let s = solve3(ata, atb)
        return (s[0], s[1], (s[2] + s[0] * s[0] + s[1] * s[1]).squareRoot())
    }

    static func solve3(_ a: [[Double]], _ b: [Double]) -> [Double] {
        func det(_ m: [[Double]]) -> Double {
            m[0][0] * (m[1][1] * m[2][2] - m[1][2] * m[2][1])
                - m[0][1] * (m[1][0] * m[2][2] - m[1][2] * m[2][0])
                + m[0][2] * (m[1][0] * m[2][1] - m[1][1] * m[2][0])
        }
        let d = det(a)
        guard abs(d) > 1e-12 else { return [0, 0, 0] }
        return (0..<3).map { k in
            var m = a
            for i in 0..<3 { m[i][k] = b[i] }
            return det(m) / d
        }
    }

    /// The bright limb's direction (the lit area's centroid from the disk's
    /// centre) and the lit fraction.
    static func measureLimb(
        _ l: Level, centre: (x: Double, y: Double), radius: Double
    ) -> (Double?, Double) {
        var small = l
        var factor = 1.0
        while small.width > 800 {
            small = halve(small)
            factor *= 2
        }
        let (cx, cy, r) = (centre.x / factor, centre.y / factor, radius / factor)
        let thr = litThreshold * percentile(small.pixels, 0.999)
        var sx = 0.0, sy = 0.0, lit = 0.0, all = 0.0
        for y in 0..<small.height {
            for x in 0..<small.width {
                let dx = Double(x) + 0.5 - cx
                let dy = Double(y) + 0.5 - cy
                guard dx * dx + dy * dy <= r * r else { continue }
                all += 1
                if small.pixels[y * small.width + x] > thr {
                    lit += 1
                    sx += dx
                    sy += dy
                }
            }
        }
        guard all > 0, lit > 0 else { return (nil, 0) }
        let fraction = lit / all
        let mx = sx / lit
        let my = sy / lit
        // Near full the centroid sits at the centre: no direction to measure.
        guard hypot(mx, my) > 0.03 * r else { return (nil, fraction) }
        let deg = atan2(mx, -my) * 180 / .pi
        return ((deg + 360).truncatingRemainder(dividingBy: 360), fraction)
    }
}
