import Foundation

/// The simulated camera (ADR 0022 amendment 7): a Moon scene seen through
/// configurable optics, pointed by a provider (the simulated mount, or the
/// real mount's encoders and the ephemeris), streamed at the sensor's frame
/// rate. In order: the scene sampled at the pointing (with motion blur over
/// the exposure), the sky and the Moon's glow, defocus and seeing, exposure
/// and gain into noise, the sensor's fixed pattern, 8-bit clipping. It
/// knows the truth, for scoring.
public final class SimCamera: Camera, @unchecked Sendable {
    /// What the sky and the air are doing.
    public struct Conditions: Sendable, Equatable, Codable {
        /// Seeing, the blur's full width at half maximum, arcseconds.
        public var seeingArcsec: Double = 2.5
        /// Sky brightness, against the brightest lit Moon (0 at night;
        /// about 0.1–0.4 by day, more near the Sun).
        public var skyLevel: Double = 0
        /// The Moon's glow just outside the limb (scattered light), against
        /// the lit Moon, and how fast it fades, arcseconds.
        public var glowLevel: Double = 0.02
        public var glowArcsec: Double = 300
        /// Light let through (1 clear; thin cloud 0.3–0.8).
        public var transmission: Double = 1
        public init() {}
    }

    private let lock = NSLock()
    private var _optics: SimOptics
    private var _scene: MoonScene
    private var _conditions = Conditions()
    private var _sceneRotationDeg = 0.0
    private var _moonRadiusArcsec = 930.0
    private var exposureUs = 2000
    private var gain = 100
    private var running = false
    private var nextFrame = Date.distantPast
    private var frameCount: UInt64 = 0
    private var lastPointing: (time: Date, x: Double, y: Double)?
    private var fixedPattern: [Float] = []
    private var hot: [Int] = []
    private let seed: UInt64
    private var _focuser: SimFocuser
    /// The focus knob (replaced for a new scenario, with a new best focus).
    public var focuser: SimFocuser {
        get { lock.withLock { _focuser } }
        set { lock.withLock { _focuser = newValue } }
    }

    /// Where the mount points relative to the Moon's centre, arcseconds
    /// (x along azimuth on the sky, y along altitude), for each frame.
    public var provider: (@Sendable () -> (x: Double, y: Double))?
    private var _pointing: (x: Double, y: Double) = (0, 0)
    public var pointing: (x: Double, y: Double) {
        get { lock.withLock { provider?() ?? _pointing } }
        set { lock.withLock { _pointing = newValue } }
    }

    /// Every frame's true pointing (after the focus shift), in order.
    public private(set) var history: [(x: Double, y: Double)] = []

    public init(
        optics: SimOptics = .sct8, scene: MoonScene, focuser: SimFocuser = SimFocuser(),
        seed: UInt64 = 1
    ) {
        _optics = optics
        _scene = scene
        _focuser = focuser
        self.seed = seed
        makeFixedPattern()
    }

    public var info: CameraInfo {
        let s = optics.sensor
        return CameraInfo(
            name: s.name, width: s.width, height: s.height, pixelSizeUm: s.pixelSizeUm,
            isColor: s.isColor, bayerPattern: s.bayerPattern)
    }

    public var optics: SimOptics {
        get { lock.withLock { _optics } }
        set {
            lock.withLock {
                let resized = newValue.sensor != _optics.sensor
                _optics = newValue
                if resized { makeFixedPatternLocked() }
            }
        }
    }
    public var scene: MoonScene {
        get { lock.withLock { _scene } }
        set { lock.withLock { _scene = newValue } }
    }
    public var conditions: Conditions {
        get { lock.withLock { _conditions } }
        set { lock.withLock { _conditions = newValue } }
    }
    /// The scene's turn on the sky, degrees clockwise as seen: the scene's
    /// up lands this far clockwise from the zenith.
    public var sceneRotationDeg: Double {
        get { lock.withLock { _sceneRotationDeg } }
        set { lock.withLock { _sceneRotationDeg = newValue } }
    }
    /// The Moon's apparent radius tonight; the scene is scaled to it.
    public var moonRadiusArcsec: Double {
        get { lock.withLock { _moonRadiusArcsec } }
        set { lock.withLock { _moonRadiusArcsec = newValue } }
    }

    /// Turns the scene so its bright limb points where the ephemeris says
    /// (degrees clockwise from the zenith). Scenes without a measurable limb
    /// (near full) are left as they are.
    public func alignBrightLimb(toDeg limb: Double) {
        guard let own = scene.brightLimbDeg else { return }
        sceneRotationDeg = limb - own
    }

    // MARK: - Camera

    public func configure(exposureUs: Int, gain: Int) throws {
        lock.withLock {
            self.exposureUs = max(exposureUs, 32)
            self.gain = gain
        }
    }
    public func start() throws { lock.withLock { running = true } }
    public func stop() { lock.withLock { running = false } }

    public func frame(timeoutMs: Int) throws -> Frame? {
        // Frames come at the sensor's rate (or the exposure's, if slower).
        let (fps, exposure) = lock.withLock { (_optics.sensor.fps, exposureUs) }
        let interval = max(1 / fps, Double(exposure) / 1e6)
        let now = Date()
        let due = lock.withLock { nextFrame }
        if due > now {
            let wait = due.timeIntervalSince(now)
            if wait * 1000 > Double(max(timeoutMs, 0)) && timeoutMs > 0 { return nil }
            Thread.sleep(forTimeInterval: wait)
        }
        let taken = Date()
        lock.withLock { nextFrame = max(due, taken) + interval }
        return render(at: taken)
    }

    /// The sky point (arcseconds from the Moon's centre) that pixel (u, v)
    /// from the frame's centre sees, at best focus and the given pointing.
    /// The same mapping as `FakeCamera`'s.
    public func sky(u: Double, v: Double, pointing p: (x: Double, y: Double)) -> (x: Double, y: Double) {
        let o = optics
        let u = o.diagonal ? -u : u
        let t = o.cameraRotationDeg * .pi / 180
        let s = o.arcsecPerPixel
        return (p.x + s * (u * cos(t) - v * sin(t)), p.y - s * (u * sin(t) + v * cos(t)))
    }

    // MARK: - Rendering

    func render(at taken: Date) -> Frame {
        let p0 = pointing
        let focus = focuser.effect
        let (o, scene, c, rot, radius, exposure, g, n) = lock.withLock {
            frameCount += 1
            return (_optics, _scene, _conditions, _sceneRotationDeg, _moonRadiusArcsec, exposureUs, gain, frameCount)
        }
        var rng = Rng(seed &+ n &* 0x9E37_79B9_7F4A_7C15)
        // Seeing: this frame's blur and its tip-tilt.
        let seeing = c.seeingArcsec * (0.75 + 0.5 * rng.uniform())
        let jitter = (0.3 * c.seeingArcsec * rng.gaussian(), 0.3 * c.seeingArcsec * rng.gaussian())
        let p = (x: p0.x - focus.shift.x + jitter.0, y: p0.y - focus.shift.y + jitter.1)
        // Motion over the exposure, from the last frame's pointing.
        var velocity = (x: 0.0, y: 0.0)
        lock.withLock {
            if let last = lastPointing {
                let dt = taken.timeIntervalSince(last.time)
                if dt > 0.001, dt < 1 { velocity = ((p0.x - last.x) / dt, (p0.y - last.y) / dt) }
            }
            lastPointing = (taken, p0.x, p0.y)
            history.append(p)
        }
        let (w, h) = (o.sensor.width, o.sensor.height)
        let scale = o.arcsecPerPixel / focus.scale
        let exposureS = Double(exposure) / 1e6
        let smear = hypot(velocity.x, velocity.y) * exposureS / scale
        let taps = min(max(Int(smear.rounded(.up)), 1), 8)

        // Output pixel (x, y) → sky → scene (level 0) as one affine map.
        let t = o.cameraRotationDeg * .pi / 180
        let (ct, st) = (cos(t), sin(t))
        let m = o.diagonal ? -1.0 : 1.0
        let r = rot * .pi / 180
        let (cr, sr) = (cos(r), sin(r))
        let k = radius / scene.radius
        let level = scene.level(forStep: scale / k)
        let lf = Double(1 << level)
        // sky q = p + scale·(m·u·ct − v·st, −(m·u·st + v·ct)); u = x − w/2, v = y − h/2
        let qxu = scale * m * ct, qxv = -scale * st
        let qyu = -scale * m * st, qyv = -scale * ct
        // scene s0 = R(rot)·q; X = cx + s0x/k, Y = cy − s0y/k (in level pixels: ÷ lf)
        let toScene: @Sendable (Double, Double) -> (Double, Double) = { qx, qy in
            let sx = cr * qx - sr * qy
            let sy = sr * qx + cr * qy
            return ((scene.centre.x + sx / k) / lf, (scene.centre.y - sy / k) / lf)
        }
        let dxu = (cr * qxu - sr * qyu) / k / lf
        let dyu = -(sr * qxu + cr * qyu) / k / lf

        var light = [Float](repeating: 0, count: w * h)
        let glow = Float(c.glowLevel)
        let glowScale = c.glowArcsec
        let sky = Float(c.skyLevel)
        let vel = velocity
        let lvl = scene.levels[level]
        let (lw, lh) = (lvl.width, lvl.height)
        let weight = 1 / Float(taps)
        light.withUnsafeMutableBufferPointer { out in
            lvl.pixels.withUnsafeBufferPointer { src in
                nonisolated(unsafe) let base = out.baseAddress!
                nonisolated(unsafe) let sp = src.baseAddress!
                DispatchQueue.concurrentPerform(iterations: (h + 15) / 16) { chunk in
                    for y in (chunk * 16)..<min(h, chunk * 16 + 16) {
                        let v = Double(y) - Double(h) / 2
                        let row = base + y * w
                        for tap in 0..<taps {
                            // Taps spread the pointing along the motion.
                            let f = taps == 1 ? 0 : (Double(tap) / Double(taps - 1) - 0.5) * exposureS
                            let u0 = -Double(w) / 2
                            var qx = p.x + vel.x * f + qxu * u0 + qxv * v
                            var qy = p.y + vel.y * f + qyu * u0 + qyv * v
                            var (sx, sy) = toScene(qx, qy)
                            for x in 0..<w {
                                // Bilinear sample of the scene (0 off its edge).
                                var b: Float = 0
                                let fx = sx - 0.5, fy = sy - 0.5
                                let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
                                if x0 >= 0, y0 >= 0, x0 + 1 < lw, y0 + 1 < lh {
                                    let ax = Float(fx - Double(x0)), ay = Float(fy - Double(y0))
                                    let i = y0 * lw + x0
                                    let top = sp[i] + (sp[i + 1] - sp[i]) * ax
                                    let bottom = sp[i + lw] + (sp[i + lw + 1] - sp[i + lw]) * ax
                                    b = top + (bottom - top) * ay
                                }
                                if glow > 0 {
                                    let d = (qx * qx + qy * qy).squareRoot() - radius
                                    if d > 0 { b += glow * Float(exp(-d / glowScale)) }
                                }
                                row[x] += (b + sky) * weight
                                sx += dxu
                                sy += dyu
                                qx += qxu
                                qy += qyu
                            }
                        }
                    }
                }
            }
        }
        // Defocus (a disk, taken as a Gaussian of a quarter its diameter)
        // and seeing, in pixels.
        let sigma = ((focus.blurArcsec / 4) * (focus.blurArcsec / 4) + (seeing / 2.355) * (seeing / 2.355))
            .squareRoot() / scale
        if sigma > 0.3 { Self.blur(&light, w, h, sigma: sigma) }

        // Exposure and gain to 8-bit counts, with noise and the sensor's pattern.
        let gf = pow(10, Double(g - 100) / 200)
        let signalScale = Float(200 * Double(exposure) / 2000 * gf * c.transmission)
        let pattern = lock.withLock { fixedPattern }
        let hotPixels = lock.withLock { hot }
        let shot = Float(0.02 * gf)
        let read = Float(0.6 * gf)
        let colour = o.sensor.isColor
        // Which cell of each 2×2 is red and which blue (RG/GB, BG/GR, GR/BG, GB/RG).
        let redCell = [0, 3, 1, 2][min(max(o.sensor.bayerPattern, 0), 3)]
        let blueCell = 3 - redCell
        var pixels = [UInt8](repeating: 0, count: w * h)
        pixels.withUnsafeMutableBufferPointer { outp in
            light.withUnsafeBufferPointer { inp in
                pattern.withUnsafeBufferPointer { fp in
                    nonisolated(unsafe) let ob = outp.baseAddress!
                    nonisolated(unsafe) let ib = inp.baseAddress!
                    nonisolated(unsafe) let pb = fp.baseAddress!
                    let rowSeed = rng.next()
                    DispatchQueue.concurrentPerform(iterations: (h + 15) / 16) { chunk in
                        var nr = Rng(rowSeed &+ UInt64(chunk) &* 0xD1B5_4A32_D192_ED03)
                        for y in (chunk * 16)..<min(h, chunk * 16 + 16) {
                            for x in 0..<w {
                                let i = y * w + x
                                var resp: Float = 1
                                if colour {
                                    let cell = (y & 1) * 2 + (x & 1)
                                    resp = cell == redCell ? 0.75 : cell == blueCell ? 0.6 : 1
                                }
                                let dn = ib[i] * signalScale * resp
                                let sd = (shot * max(dn, 0) + read * read).squareRoot()
                                let v = 4 + dn + sd * Float(nr.gaussian()) + pb[i] * Float(gf)
                                ob[i] = UInt8(max(0, min(255, v.rounded())))
                            }
                        }
                    }
                }
            }
            for i in hotPixels { outp[i] = UInt8(min(255, Int(outp[i]) + Int(60 * Double(exposure) / 2000 * gf))) }
        }
        return Frame(width: w, height: h, pixels: pixels, time: taken)
    }

    /// Three box passes each way: close to a Gaussian of this sigma.
    static func blur(_ a: inout [Float], _ w: Int, _ h: Int, sigma: Double) {
        let radius = max(1, Int(((12 * sigma * sigma / 3 + 1).squareRoot() - 1) / 2 + 0.5))
        var tmp = [Float](repeating: 0, count: a.count)
        for _ in 0..<3 {
            boxRows(a, &tmp, w, h, radius)
            boxColumns(tmp, &a, w, h, radius)
        }
    }

    static func boxRows(_ src: [Float], _ dst: inout [Float], _ w: Int, _ h: Int, _ r: Int) {
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                nonisolated(unsafe) let sb = s.baseAddress!
                nonisolated(unsafe) let db = d.baseAddress!
                let norm = 1 / Float(2 * r + 1)
                DispatchQueue.concurrentPerform(iterations: h) { y in
                    let row = sb + y * w, out = db + y * w
                    var acc: Float = 0
                    for i in -r...r { acc += row[min(max(i, 0), w - 1)] }
                    for x in 0..<w {
                        out[x] = acc * norm
                        acc += row[min(x + r + 1, w - 1)] - row[max(x - r, 0)]
                    }
                }
            }
        }
    }

    static func boxColumns(_ src: [Float], _ dst: inout [Float], _ w: Int, _ h: Int, _ r: Int) {
        src.withUnsafeBufferPointer { s in
            dst.withUnsafeMutableBufferPointer { d in
                nonisolated(unsafe) let sb = s.baseAddress!
                nonisolated(unsafe) let db = d.baseAddress!
                let norm = 1 / Float(2 * r + 1)
                let strip = 64
                DispatchQueue.concurrentPerform(iterations: (w + strip - 1) / strip) { k in
                    let x0 = k * strip, x1 = min(w, x0 + strip)
                    var acc = [Float](repeating: 0, count: x1 - x0)
                    for i in -r...r {
                        let yy = min(max(i, 0), h - 1)
                        for x in x0..<x1 { acc[x - x0] += sb[yy * w + x] }
                    }
                    for y in 0..<h {
                        let add = min(y + r + 1, h - 1) * w, sub = max(y - r, 0) * w
                        for x in x0..<x1 {
                            db[y * w + x] = acc[x - x0] * norm
                            acc[x - x0] += sb[add + x] - sb[sub + x]
                        }
                    }
                }
            }
        }
    }

    private func makeFixedPattern() { lock.withLock { makeFixedPatternLocked() } }

    /// The sensor's fixed pattern: a small offset per pixel and per column,
    /// the same every frame, and a few hot pixels. (On 2026-11-19 the fixed
    /// pattern pulled frame matches toward zero shift.)
    private func makeFixedPatternLocked() {
        let (w, h) = (_optics.sensor.width, _optics.sensor.height)
        var rng = Rng(seed ^ 0x5EED_F1A7)
        let columns = (0..<w).map { _ in Float(0.4 * rng.gaussian()) }
        fixedPattern = (0..<(w * h)).map { i in Float(0.6 * rng.gaussian()) + columns[i % w] }
        hot = (0..<max(1, w * h / 10_000)).map { _ in Int(rng.next() % UInt64(w * h)) }
    }
}

/// A small, fast, seeded generator (SplitMix64).
struct Rng {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }
    /// Roughly normal (the sum of four uniforms), cheap enough per pixel.
    mutating func gaussian() -> Double {
        (uniform() + uniform() + uniform() + uniform() - 2) * 1.732
    }
}
