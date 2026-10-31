import Foundation
import Testing

@testable import MoonMosaicCore

/// Two calibration moves on the fake camera recover its scale and rotation,
/// and a planned tile's pointing shows the part of the Moon it was planned for.
@Test func calibrationRecoversScaleAndRotation() throws {
    let camera = FakeCamera(scale: 0.6, rotationDeg: 30)
    let reference = try #require(try camera.frame(timeoutMs: 0))
    camera.pointing = (60, 0)
    let afterAz = try #require(try camera.frame(timeoutMs: 0))
    camera.pointing = (60, 60)
    let afterAlt = try #require(try camera.frame(timeoutMs: 0))
    let s1 = Registration.shift(from: reference, to: afterAz)
    let s2 = Registration.shift(from: afterAz, to: afterAlt)
    let calibration = try #require(
        CameraCalibration(
            (SkyOffset(x: 60, y: 0), PixelOffset(x: s1.dx, y: s1.dy)),
            (SkyOffset(x: 0, y: 60), PixelOffset(x: s2.dx, y: s2.dy))))
    #expect(abs(calibration.arcsecPerPixel - 0.6) < 0.01, "\(calibration.arcsecPerPixel)")

    // A tile planned at pixel c of the reference frame: pointing there puts
    // the sky point the reference frame saw at c in the middle of the frame.
    let plan = MosaicPlanner.plan(
        moonDiameterDeg: 0.52, calibration: calibration, frameWidth: 640, frameHeight: 360)
    let tile = plan.tiles[plan.tiles.count / 3]
    camera.pointing = (0, 0)
    let want = camera.sky(u: tile.center.x, v: tile.center.y)
    #expect(abs(tile.pointing.x - want.x) < 1.5, "\(tile.pointing) vs \(want)")
    #expect(abs(tile.pointing.y - want.y) < 1.5, "\(tile.pointing) vs \(want)")
}

/// Calibration solves for any two non-parallel moves, including the Moon's
/// drift mixed into both.
@Test func calibrationSolvesMixedMoves() throws {
    let truth = CameraCalibration(a: 1.2, b: -0.7, c: 0.6, d: 1.4)
    let m1 = SkyOffset(x: 50, y: 8)
    let m2 = SkyOffset(x: -6, y: 45)
    let cal = try #require(
        CameraCalibration((m1, truth.image(for: m1)), (m2, truth.image(for: m2))))
    #expect(abs(cal.a - 1.2) < 1e-9 && abs(cal.d - 1.4) < 1e-9)
    let back = cal.sky(for: cal.image(for: SkyOffset(x: 13, y: -21)))
    #expect(abs(back.x - 13) < 1e-9 && abs(back.y + 21) < 1e-9)
    #expect(CameraCalibration((m1, truth.image(for: m1)), (m1, truth.image(for: m1))) == nil)
}

/// The ASI662MC at 2000 mm on a 0.52° Moon: about 30–40 tiles with 25%
/// overlap, every point of the disk inside a tile, neighbours overlapping.
@Test func thePlanCoversTheDisk() {
    // 0.30″ per pixel, camera turned 20°.
    let k = 1 / 0.30
    let t = 20 * Double.pi / 180
    let cal = CameraCalibration(a: k * cos(t), b: -k * sin(t), c: k * sin(t), d: k * cos(t))
    let plan = MosaicPlanner.plan(
        moonDiameterDeg: 0.52, calibration: cal, frameWidth: 1920, frameHeight: 1080)
    #expect(plan.tiles.count >= 25 && plan.tiles.count <= 45, "\(plan.tiles.count) tiles")
    let r = plan.moonRadiusPixels
    for y in stride(from: -r, through: r, by: r / 40) {
        for x in stride(from: -r, through: r, by: r / 40) where x * x + y * y <= r * r {
            let covered = plan.tiles.contains {
                abs(x - $0.center.x) <= 960 && abs(y - $0.center.y) <= 540
            }
            #expect(covered, "(\(x), \(y)) not covered")
            if !covered { return }
        }
    }
    // Serpentine: consecutive tiles in a row are one step apart.
    for (p, q) in zip(plan.tiles, plan.tiles.dropFirst()) where p.row == q.row {
        #expect(abs(abs(p.center.x - q.center.x) - 1920 * 0.75) < 1e-6)
    }
}

@Test func axesWidenAzimuthByAltitude() {
    let m = MosaicPlanner.axes(for: SkyOffset(x: 3600, y: 1800), altitudeDeg: 60)
    #expect(abs(m.azDeg - 2) < 1e-9 && abs(m.altDeg - 0.5) < 1e-9)
}
