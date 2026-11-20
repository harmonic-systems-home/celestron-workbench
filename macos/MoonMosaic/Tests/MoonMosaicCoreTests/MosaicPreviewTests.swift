import Foundation
import Testing

@testable import MoonMosaicCore

/// Tiles of a synthetic Moon, placed by plan, give a seamless mosaic; the
/// missing, failed and soft tiles are flagged.
@Test func thePreviewPlacesTilesAndFlagsProblems() throws {
    let camera = FakeCamera(width: 640, height: 360, scale: 3, rotationDeg: 0)
    let k = 1 / 3.0
    // Pointing right moves the image left, pointing up moves it down.
    let cal = CameraCalibration(a: -k, b: 0, c: 0, d: k)
    let plan = MosaicPlanner.plan(
        moonDiameterDeg: 0.52, calibration: cal, frameWidth: 640, frameHeight: 360)
    #expect(plan.tiles.count > 4)
    var stacks: [Int: QuickStack] = [:]
    var states: [Int: TileState] = [:]
    for tile in plan.tiles.dropLast(2) {
        camera.pointing = (tile.pointing.x, tile.pointing.y)
        var stack = QuickStack(keep: 2)
        let frame = try #require(try camera.frame(timeoutMs: 0))
        stack.offer(frame)
        stacks[tile.id] = stack
        states[tile.id] = .done(file: "", frames: 1, sharpness: stack.bestSharpness)
    }
    let last = plan.tiles[plan.tiles.count - 1].id
    states[last] = .failed("test")
    let preview = MosaicPreview.make(plan: plan, stacks: stacks, states: states)

    #expect(preview.failed == [last])
    #expect(preview.missing == [plan.tiles[plan.tiles.count - 2].id])
    // The Moon's centre (bright) and a corner (dark sky) where they should be.
    let cx = preview.width / 2
    let cy = preview.height / 2
    #expect(preview.pixels[cy * preview.width + cx] > 0.3)
    #expect(preview.pixels[0] < 0.1)
    #expect(preview.soft.isEmpty, "soft \(preview.soft)")
    // A soft tile: blurred, so its shared strips are less sharp than its
    // neighbours' views of the same Moon.
    let middle = try #require(plan.tiles.min { hypot($0.center.x, $0.center.y) < hypot($1.center.x, $1.center.y) })
    camera.pointing = (middle.pointing.x, middle.pointing.y)
    var blurred = QuickStack(keep: 1)
    blurred.offer(boxBlur(try #require(try camera.frame(timeoutMs: 0)), radius: 8))
    stacks[middle.id] = blurred
    states[middle.id] = .done(file: "", frames: 1, sharpness: blurred.bestSharpness)
    #expect(MosaicPreview.make(plan: plan, stacks: stacks, states: states).soft == [middle.id])
}

private func boxBlur(_ f: Frame, radius r: Int) -> Frame {
    var out = [UInt8](repeating: 0, count: f.pixels.count)
    for y in 0..<f.height {
        for x in 0..<f.width {
            var (s, n) = (0, 0)
            for yy in max(0, y - r)...min(f.height - 1, y + r) {
                for xx in max(0, x - r)...min(f.width - 1, x + r) {
                    s += Int(f.pixels[yy * f.width + xx])
                    n += 1
                }
            }
            out[y * f.width + x] = UInt8(s / n)
        }
    }
    return Frame(width: f.width, height: f.height, pixels: out, time: f.time)
}
