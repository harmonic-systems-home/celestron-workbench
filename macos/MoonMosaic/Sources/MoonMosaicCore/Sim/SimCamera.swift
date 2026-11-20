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
        /// the lit Moon, and how fast it fades, arcseconds. Moonlit sky near
        /// the Moon is about 10⁻⁵–10⁻⁴ of the lit surface per unit area; haze
        /// and the optics' own scatter raise it. Orient Moon's survey frames
        /// are 500 times brighter than the video, so 10⁻⁴ already reads 10
        /// counts there, and 10⁻³ saturates.
        public var glowLevel: Double = 0.0001
        public var glowArcsec: Double = 300
        /// Light let through (1 clear; thin cloud 0.3–0.8).
        public var transmission: Double = 1
        /// Shake after a move: the tube rings at `shakeHz`, dying away over
        /// `shakeSeconds`, starting at up to `shakeArcsec` (bigger after a
        /// faster move) along the move's direction. 0 for none.
        public var shakeArcsec: Double = 20
        public var shakeHz: Double = 2
        public var shakeSeconds: Double = 0.8
        /// Faults: the share of frames lost (each frame call returns nil),
        /// and a camera that stops delivering until a moment (USB trouble).
        public var dropFrames: Double = 0
        /// The atmosphere beyond blur: the whole image's tip-tilt wanders
        /// (RMS 0.3 × seeing) with this time constant, and parts of the
        /// image move against each other (shimmer, RMS `shimmerArcsec`) over
        /// patches about `patchArcsec` across, changing a few times a second.
        public var tiltSeconds: Double = 0.05
        public var shimmerArcsec: Double = 0.6
        public var patchArcsec: Double = 30
        public var stalledUntil: Date? = nil
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
    /// The last move's end, for the shake: when, how hard, which way.
    private var moving = false
    private var peakSpeed = 0.0
    private var moveDirection = (x: 0.0, y: 0.0)
    private var shakeStart: (time: Date, amplitude: Double, x: Double, y: Double)?
    /// The tip-tilt's state (arcseconds) and when it was last drawn.
    private var tilt = (x: 0.0, y: 0.0, time: Date.distantPast)
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
    /// Turns the scene so its lunar north (the sidecar's `northDeg`) points
    /// where the ephemeris puts it (`Ephemeris.moonNorthFromZenithDeg`):
    /// exact at any phase, full Moon included. False without `northDeg`.
    @discardableResult
    public func alignNorth(toDeg north: Double) -> Bool {
        guard let own = scene.info.northDeg else { return false }
        sceneRotationDeg = north - own
        return true
    }

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
        let (drop, stalled) = lock.withLock { (_conditions.dropFrames, _conditions.stalledUntil) }
        if let stalled, stalled > Date() {
            Thread.sleep(forTimeInterval: min(stalled.timeIntervalSinceNow, Double(max(timeoutMs, 1)) / 1000))
            return nil
        }
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
        if drop > 0, Double.random(in: 0..<1) < drop { return nil }
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
        // Tip-tilt: a random walk pulled back to zero (AR(1)), so frames
        // taken close together move together, as through real air.
        let sd = 0.3 * c.seeingArcsec
        let jitter: (Double, Double) = lock.withLock {
            let dt = max(0, taken.timeIntervalSince(tilt.time))
            let rho = c.tiltSeconds > 0 ? exp(-dt / c.tiltSeconds) : 0
            let fresh = (1 - rho * rho).squareRoot() * sd
            tilt = (tilt.x * rho + fresh * rng.gaussian(), tilt.y * rho + fresh * rng.gaussian(), taken)
            return (tilt.x, tilt.y)
        }
        var p = (x: p0.x - focus.shift.x + jitter.0, y: p0.y - focus.shift.y + jitter.1)
        // Motion over the exposure, from the last frame's pointing.
        var velocity = (x: 0.0, y: 0.0)
        lock.withLock {
            if let last = lastPointing {
                let dt = taken.timeIntervalSince(last.time)
                // Only from a frame just before: with frames far apart (a
                // survey's, after a hop) the hop happened between them, not
                // during this exposure (2026-11-20, the test runner: survey
                // frames smeared by their own hop).
                let close = max(0.1, 3 * Double(exposure) / 1e6)
                if dt > 0.001, dt < close { velocity = ((p0.x - last.x) / dt, (p0.y - last.y) / dt) }
            }
            lastPointing = (taken, p0.x, p0.y)
            history.append(p)
            if history.count > 4000 { history.removeFirst(2000) }
            // A move ends when the pointing slows below 20″/s after going
            // faster than 40″/s; the shake starts then.
            let speed = hypot(velocity.x, velocity.y)
            if speed > 40 {
                if !moving { peakSpeed = 0 }
                moving = true
                if speed > peakSpeed {
                    peakSpeed = speed
                    moveDirection = (velocity.x / speed, velocity.y / speed)
                }
            } else if moving, speed < 20 {
                moving = false
                let a = min(c.shakeArcsec, c.shakeArcsec * peakSpeed / 1800)
                if a > 0 { shakeStart = (taken, a, moveDirection.x, moveDirection.y) }
            }
        }
        // The ringing, added to where the image falls.
        var shake = (x: 0.0, y: 0.0)
        if let s = lock.withLock({ shakeStart }), c.shakeSeconds > 0 {
            let dt = taken.timeIntervalSince(s.time)
            if dt < 5 * c.shakeSeconds {
                let amp = s.amplitude * exp(-dt / c.shakeSeconds) * cos(2 * .pi * c.shakeHz * dt)
                shake = (amp * s.x, amp * s.y)
            }
        }
        p = (x: p.x + shake.x, y: p.y + shake.y)
        let pFinal = p
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
        let dxv = (cr * qxv - sr * qyv) / k / lf
        let dyv = -(sr * qxv + cr * qyv) / k / lf
        // Shimmer: a few drifting waves of displacement (image pixels),
        // worked out on a coarse grid and interpolated.
        let cell = 32
        let (gw, gh) = (w / cell + 2, h / cell + 2)
        var grid = [Double](repeating: 0, count: gw * gh * 2)
        if c.shimmerArcsec > 0, c.patchArcsec > 0 {
            var modeRng = Rng(seed &* 0x2545_F491_4F6C_DD1D &+ 7)
            let time = taken.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 10_000)
            let lambda = c.patchArcsec * 2 / scale
            let amp = c.shimmerArcsec / scale / 2.0.squareRoot()
            for _ in 0..<4 {
                let dir = 2 * Double.pi * modeRng.uniform()
                let (kx, ky) = (cos(dir) * 2 * .pi / lambda, sin(dir) * 2 * .pi / lambda)
                let pol = 2 * Double.pi * modeRng.uniform()
                let omega = 2 * Double.pi * (1 + 4 * modeRng.uniform())
                let phase = 2 * Double.pi * modeRng.uniform()
                let a = amp / 2 * (0.5 + modeRng.uniform())
                for gy in 0..<gh {
                    for gx in 0..<gw {
                        let s = a * sin(kx * Double(gx * cell) + ky * Double(gy * cell) + omega * time + phase)
                        grid[(gy * gw + gx) * 2] += s * cos(pol)
                        grid[(gy * gw + gx) * 2 + 1] += s * sin(pol)
                    }
                }
            }
        }
        let shimmer = c.shimmerArcsec > 0

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
                        // This row's shimmer at each grid column, in scene steps.
                        let gy = y / cell, fy = Double(y % cell) / Double(cell)
                        var rowShift = [(Double, Double)](repeating: (0, 0), count: gw)
                        if shimmer {
                            for gx in 0..<gw {
                                let i0 = (gy * gw + gx) * 2, i1 = ((gy + 1) * gw + gx) * 2
                                let du = grid[i0] + (grid[i1] - grid[i0]) * fy
                                let dv = grid[i0 + 1] + (grid[i1 + 1] - grid[i0 + 1]) * fy
                                rowShift[gx] = (du * dxu + dv * dxv, du * dyu + dv * dyv)
                            }
                        }
                        for tap in 0..<taps {
                            // Taps spread the pointing along the motion.
                            let f = taps == 1 ? 0 : (Double(tap) / Double(taps - 1) - 0.5) * exposureS
                            let u0 = -Double(w) / 2
                            var qx = pFinal.x + vel.x * f + qxu * u0 + qxv * v
                            var qy = pFinal.y + vel.y * f + qyu * u0 + qyv * v
                            var (sx, sy) = toScene(qx, qy)
                            for x in 0..<w {
                                // Bilinear sample of the scene (0 off its edge).
                                var b: Float = 0
                                var (wx, wy) = (sx, sy)
                                if shimmer {
                                    let g = x / cell, f = Double(x % cell) / Double(cell)
                                    let (a0, a1) = (rowShift[g], rowShift[g + 1])
                                    wx += a0.0 + (a1.0 - a0.0) * f
                                    wy += a0.1 + (a1.1 - a0.1) * f
                                }
                                let fx = wx - 0.5, fy = wy - 0.5
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
