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
    // A soft tile: much less sharp than the rest.
    let first = plan.tiles[0].id
    states[first] = .done(file: "", frames: 1, sharpness: 0)
    #expect(MosaicPreview.make(plan: plan, stacks: stacks, states: states).soft == [first])
}
