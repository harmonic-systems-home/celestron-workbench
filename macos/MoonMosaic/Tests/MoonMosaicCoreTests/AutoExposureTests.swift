import Foundation
import Testing

@testable import MoonMosaicCore

/// Auto-set (amendment 7): from too bright or too dark, it settles with the
/// bright end just below clipping, preferring short exposures.
@Test(arguments: [(30_000, 300), (200, 0), (2_000, 100)])
func autoSetSettlesBelowClipping(start: (Int, Int)) async throws {
    let mount = try MountSession(port: "simulate")
    let camera = FakeCamera()
    var settings = MosaicSettings(site: Site(latitudeDeg: 40, longitudeDeg: -100))
    (settings.exposureUs, settings.gain) = start
    let session = MosaicSession(mount: mount, camera: camera, settings: settings)
    let s = try await session.autoExposure()
    #expect(s.settled, "\(s)")
    #expect(s.clipped <= 0.001)
    let (e, g) = (session.settings.exposureUs, session.settings.gain)
    // The Moon's middle at 2 ms gain 100 is mid-scale in the fake camera, so
    // the answer needs no long exposure.
    #expect(e <= 5_000, "exposure \(e) µs at gain \(g)")
    let f = try #require(try { () throws -> Frame? in
        try camera.configure(exposureUs: e, gain: g)
        try camera.start()
        defer { camera.stop() }
        return try camera.frame(timeoutMs: 1000)
    }())
    let end = AutoExposure.brightEnd(f)
    #expect(end.level > 180 && end.level < 254, "bright end \(end)")
}

@Test func suggestionPrefersGainOverExposure() {
    // A dim frame at 10 ms, gain 0: brightness is wanted ×2; it should come
    // from gain, with the exposure shortened.
    let pixels = [UInt8](repeating: 100, count: 10_000)
    let f = Frame(width: 100, height: 100, pixels: pixels, time: Date())
    let s = AutoExposure.suggest(f, exposureUs: 10_000, gain: 0)
    let before = 10_000.0
    let after = Double(s.exposureUs) * pow(10, Double(s.gain) / 200)
    #expect(abs(after / before - 2.15) < 0.05, "\(s)")
    #expect(s.exposureUs < 10_000)
}
