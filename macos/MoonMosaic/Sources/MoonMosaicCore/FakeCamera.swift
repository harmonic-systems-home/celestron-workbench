import Foundation

/// A camera looking at a synthetic Moon, for tests and rehearsals (ADR
/// 0019): a bright disk with craters and maria, seen through a known image
/// scale and rotation. Set `pointing` (where the mount points relative to
/// the Moon's centre, in arcseconds: x along azimuth on the sky, y along
/// altitude) and frames show that part of the disk.
public final class FakeCamera: Camera, @unchecked Sendable {
    public let info: CameraInfo
    /// Arcseconds per pixel, and the camera's rotation against azimuth and
    /// altitude (degrees).
    public let scale: Double
    public let rotationDeg: Double
    public let moonRadiusArcsec: Double
    private let lock = NSLock()
    private var _pointing: (x: Double, y: Double) = (0, 0)
    private var running = false
    /// Craters by 100″ cell in a flat grid, so each pixel checks only its
    /// neighbourhood, cheaply.
    private let craters: [[(x: Double, y: Double, r: Double, depth: Double)]]
    private let cells: Int
    private static let cell = 100.0

    /// Where the mount points relative to the Moon, set directly or, with a
    /// provider, computed for each frame (a simulated mount and the Moon's
    /// motion).
    public var pointing: (x: Double, y: Double) {
        get { lock.withLock { provider?() ?? _pointing } }
        set { lock.withLock { _pointing = newValue } }
    }
    public var provider: (@Sendable () -> (x: Double, y: Double))?
    /// Every frame's pointing, in order, for tests.
    public private(set) var history: [(x: Double, y: Double)] = []

    public init(
        width: Int = 640, height: Int = 360, scale: Double = 0.6, rotationDeg: Double = 30,
        moonRadiusArcsec: Double = 930, seed: UInt64 = 1
    ) {
        info = CameraInfo(
            name: "Fake Moon", width: width, height: height, pixelSizeUm: 2.9, isColor: false,
            bayerPattern: 0)
        self.scale = scale
        self.rotationDeg = rotationDeg
        self.moonRadiusArcsec = moonRadiusArcsec
        var rng = seed
        func next() -> Double {
            rng = rng &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(rng >> 11) / Double(1 << 53)
        }
        // Cells from −n to n−1 on each axis, plus a border of empty ones.
        let n = Int((moonRadiusArcsec / Self.cell).rounded(.up)) + 2
        cells = n
        var grid = [[(x: Double, y: Double, r: Double, depth: Double)]](
            repeating: [], count: 4 * n * n)
        for _ in 0..<900 {
            let c = (
                x: (next() * 2 - 1) * moonRadiusArcsec, y: (next() * 2 - 1) * moonRadiusArcsec,
                r: 8 + 40 * pow(next(), 3), depth: 0.2 + 0.5 * next()
            )
            let i = Int((c.x / Self.cell).rounded(.down)) + n
            let j = Int((c.y / Self.cell).rounded(.down)) + n
            grid[i * 2 * n + j].append(c)
        }
        craters = grid
    }

    public func configure(exposureUs: Int, gain: Int) throws {}
    public func start() throws { running = true }
    public func stop() { running = false }

    /// The sky point (arcseconds from the Moon's centre) that pixel (u, v),
    /// measured from the frame's centre, sees.
    public func sky(u: Double, v: Double) -> (x: Double, y: Double) {
        sky(u: u, v: v, pointing: pointing)
    }

    func sky(u: Double, v: Double, pointing p: (x: Double, y: Double)) -> (x: Double, y: Double) {
        let t = rotationDeg * .pi / 180
        return (
            p.x + scale * (u * cos(t) - v * sin(t)), p.y - scale * (u * sin(t) + v * cos(t))
        )
    }

    public func frame(timeoutMs: Int) throws -> Frame? {
        let (w, h) = (info.width, info.height)
        var pixels = [UInt8](repeating: 0, count: w * h)
        let r2 = moonRadiusArcsec * moonRadiusArcsec
        // One pointing for the whole frame, and the frame stamped then: that
        // is the moment it shows, however long it takes to draw.
        let taken = Date()
        let p = pointing
        lock.withLock { history.append(p) }
        let t = rotationDeg * .pi / 180
        let (ct, st) = (cos(t), sin(t))
        let n = cells
        for y in 0..<h {
            let v = Double(y) - Double(h) / 2
            for x in 0..<w {
                let u = Double(x) - Double(w) / 2
                let q = (x: p.x + scale * (u * ct - v * st), y: p.y - scale * (u * st + v * ct))
                let d2 = q.x * q.x + q.y * q.y
                guard d2 < r2 else {
                    pixels[y * w + x] = 6
                    continue
                }
                // Maria and highlands, then craters.
                var b = 0.62 + 0.18 * sin(q.x / 210) * cos(q.y / 170) + 0.08 * sin((q.x + q.y) / 47)
                let cx = Int((q.x / Self.cell).rounded(.down)) + n
                let cy = Int((q.y / Self.cell).rounded(.down)) + n
                for i in (cx - 1)...(cx + 1) where i >= 0 && i < 2 * n {
                    for j in (cy - 1)...(cy + 1) where j >= 0 && j < 2 * n {
                        for c in craters[i * 2 * n + j] {
                            let dx = q.x - c.x
                            let dy = q.y - c.y
                            let rr = (dx * dx + dy * dy) / (c.r * c.r)
                            if rr < 1.4 { b += rr < 1 ? -c.depth * (1 - rr) * 0.5 : c.depth * 0.25 }
                        }
                    }
                }
                pixels[y * w + x] = UInt8(max(10, min(245, b * 200)))
            }
        }
        return Frame(width: w, height: h, pixels: pixels, time: taken)
    }
}
