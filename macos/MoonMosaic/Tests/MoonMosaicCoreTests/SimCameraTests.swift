import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import MoonMosaicCore

/// The simulated camera (ADR 0022 amendment 7): scenes, optics, focus and
/// exposure behave as the real ones do, so the app's steps can be tested
/// against it.

private let scene = MoonScene.synthetic(size: 512, phaseAngleDeg: 60, brightLimbDeg: 90)

/// A still, sharp camera on a small sensor, unless the test changes it.
private func camera(_ optics: SimOptics = SimOptics(focalLengthMm: 2032, sensor: .testMono))
    -> SimCamera
{
    let c = SimCamera(optics: optics, scene: scene)
    var cond = SimCamera.Conditions()
    cond.seeingArcsec = 0
    c.conditions = cond
    try? c.configure(exposureUs: 2000, gain: 100)
    return c
}

/// The content shift (pixels, x right, y down) that moving the pointing by
/// `d` arcseconds should cause, from the camera's own mapping.
private func expectedShift(_ c: SimCamera, _ d: (x: Double, y: Double)) -> (Double, Double) {
    let o = c.sky(u: 0, v: 0, pointing: (0, 0))
    let ex = c.sky(u: 1, v: 0, pointing: (0, 0))
    let ey = c.sky(u: 0, v: 1, pointing: (0, 0))
    let (a, b) = (ex.x - o.x, ey.x - o.x)
    let (cc, dd) = (ex.y - o.y, ey.y - o.y)
    let det = a * dd - b * cc
    // A·s = −d
    return ((-d.x * dd + d.y * b) / det, (-d.y * a + d.x * cc) / det)
}

@Test func syntheticSceneHasItsDiskAndBrightLimb() throws {
    // Refit from the pixels alone.
    let refit = MoonScene(
        name: "refit", width: scene.width, height: scene.height, pixels: scene.levels[0].pixels)
    #expect(abs(refit.centre.x - 256.5) < 1.5 && abs(refit.centre.y - 256.5) < 1.5, "\(refit.centre)")
    #expect(abs(refit.radius - scene.radius) < 2, "\(refit.radius) vs \(scene.radius)")
    let limb = try #require(scene.brightLimbDeg)
    #expect(abs(limb - 90) < 5, "bright limb \(limb)")
    // 60° phase angle: (1 + cos 60°) / 2 = 75% lit.
    #expect(abs(scene.litFraction - 0.75) < 0.06, "lit \(scene.litFraction)")
}

@Test(arguments: [(false, 1.0, 0.0), (true, 1.0, 25.0), (false, 2.0, -40.0)])
func movingThePointingMovesTheImageAsTheOpticsSay(diagonal: Bool, barlow: Double, turn: Double) throws {
    // A focal length at which the synthetic scene (3.6″ per scene pixel)
    // still has detail at the pixels, even through the Barlow.
    var o = SimOptics(focalLengthMm: 400, sensor: .testMono)
    o.diagonal = diagonal
    o.multiplier = barlow
    o.cameraRotationDeg = turn
    let c = camera(o)
    c.pointing = (-300, 100)
    let a = try #require(try c.frame(timeoutMs: 0))
    let d = (x: 45.0 / barlow, y: -27.0 / barlow)
    c.pointing = (-300 + d.x, 100 + d.y)
    let b = try #require(try c.frame(timeoutMs: 0))
    let s = Registration.shift(from: a, to: b)
    let e = expectedShift(c, d)
    #expect(abs(s.dx - e.0) < 0.7 && abs(s.dy - e.1) < 0.7, "found \(s), expected \(e)")
    // The scale follows the optics.
    #expect(abs(o.arcsecPerPixel - 206.265 * 2.9 / (400 * barlow)) < 1e-9)
}

@Test func theFocusKnobBlursShiftsAndFlops() throws {
    // A short focal length, so the synthetic scene's own detail reaches the
    // pixels (at 0.3″/px it is far smoother than the noise).
    let c = camera(SimOptics(focalLengthMm: 200, sensor: .testMono))
    c.pointing = (-300, 100)
    let sharp = Focus.sharpness(try #require(try c.frame(timeoutMs: 0)))
    c.focuser.turn(by: 1)
    let soft = Focus.sharpness(try #require(try c.frame(timeoutMs: 0)))
    #expect(soft < sharp * 0.5, "sharp \(sharp), a turn off \(soft)")
    // Back to the start: sharp again, but the mirror sits on its other side.
    let before = c.focuser.effect.shift
    c.focuser.turn(by: -1)
    let back = c.focuser.effect
    #expect(back.blurArcsec < 2, "blur \(back.blurArcsec)")
    #expect(hypot(back.shift.x - before.x, back.shift.y - before.y) > 1, "shift \(back.shift)")
    #expect(abs(back.scale - 1) < 0.01)
}

@Test func exposureAndGainSaturateOrStarve() throws {
    let c = camera()
    c.pointing = (-300, 100)
    try c.configure(exposureUs: 20000, gain: 200)
    let hot = try #require(try c.frame(timeoutMs: 0)).pixels
    let clipped = Double(hot.filter { $0 == 255 }.count) / Double(hot.count)
    #expect(clipped > 0.5, "clipped \(clipped)")
    try c.configure(exposureUs: 200, gain: 0)
    let dim = try #require(try c.frame(timeoutMs: 0)).pixels
    let mean = Double(dim.reduce(0) { $0 + Int($1) }) / Double(dim.count)
    #expect(mean < 15, "mean \(mean)")
}

@Test func framesComeAtTheSensorsRate() throws {
    var o = SimOptics(focalLengthMm: 2032, sensor: .testMono)
    o.sensor.fps = 20
    let c = camera(o)
    _ = try c.frame(timeoutMs: 0)
    let start = Date()
    for _ in 0..<5 { _ = try c.frame(timeoutMs: 1000) }
    let took = Date().timeIntervalSince(start)
    // Never faster than the rate (slower only when the machine is busy).
    #expect(took > 0.22, "5 frames at 20 fps took \(took) s")
}

@Test func aSceneLoadsFromAnImageFileWithItsSidecar() throws {
    // A plain lit disk, written as a PNG.
    let (w, h) = (400, 300)
    var bytes = [UInt8](repeating: 3, count: w * h)
    for y in 0..<h {
        for x in 0..<w where hypot(Double(x) + 0.5 - 220, Double(y) + 0.5 - 140) < 110 {
            bytes[y * w + x] = 210
        }
    }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("scene-\(UUID())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("disk.png")
    let image = try #require(
        CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: 0),
            provider: CGDataProvider(data: Data(bytes) as CFData)!, decode: nil,
            shouldInterpolate: false, intent: .defaultIntent))
    let dest = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(dest, image, nil)
    #expect(CGImageDestinationFinalize(dest))
    try Data(#"{"source":"test","licence":"none","northDeg":12}"#.utf8)
        .write(to: url.appendingPathExtension("json"))
    let s = try MoonScene(contentsOf: url)
    #expect(abs(s.centre.x - 220) < 1.5 && abs(s.centre.y - 140) < 1.5, "\(s.centre)")
    #expect(abs(s.radius - 110) < 1.5, "\(s.radius)")
    #expect(s.brightLimbDeg == nil, "a full disk has no bright limb")
    #expect(s.info.northDeg == 12 && s.info.source == "test")
}

@Test func fullSizeFramesRenderQuickly() throws {
    let c = SimCamera(optics: .sct8, scene: scene)
    c.pointing = (-300, 100)
    _ = try c.frame(timeoutMs: 0)
    let start = Date()
    for _ in 0..<3 { _ = c.render(at: Date()) }
    let each = Date().timeIntervalSince(start) / 3
    print("SimCamera: a 1920×1080 frame takes \(Int(each * 1000)) ms (this build)")
    // Debug builds are far slower than release; this only catches a collapse.
    #expect(each < 20.0)
}
