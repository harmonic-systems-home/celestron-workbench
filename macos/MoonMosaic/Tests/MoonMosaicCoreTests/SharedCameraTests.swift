import Foundation
import Testing

@testable import MoonMosaicCore

/// The camera keeps running until every user has stopped it, and the last
/// frame read is there for the live view.
@Test func aSharedCameraRunsUntilTheLastUserStops() throws {
    let counting = CountingCamera()
    let shared = SharedCamera(counting)
    try shared.start()
    try shared.start()
    shared.stop()
    #expect(counting.running)
    #expect(shared.latest == nil)
    let f = try #require(try shared.frame(timeoutMs: 0))
    #expect(shared.latest?.time == f.time)
    shared.stop()
    #expect(!counting.running)
    #expect(counting.starts == 1)
}

private final class CountingCamera: Camera, @unchecked Sendable {
    let info = CameraInfo(
        name: "Counting", width: 4, height: 4, pixelSizeUm: 2.9, isColor: false,
        bayerPattern: 0)
    var running = false
    var starts = 0
    func configure(exposureUs: Int, gain: Int) throws {}
    func start() throws {
        running = true
        starts += 1
    }
    func frame(timeoutMs: Int) throws -> Frame? {
        Frame(width: 4, height: 4, pixels: [UInt8](repeating: 0, count: 16), time: Date())
    }
    func stop() { running = false }
}
