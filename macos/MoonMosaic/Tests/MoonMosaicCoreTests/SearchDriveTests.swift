import Foundation
import Testing

@testable import MoonMosaicCore

/// A thread-safe call counter, to trip `cancelled` after a set number of stops.
private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}

/// Points the fake camera so the target (at `targetAz`,`targetAlt`, mount
/// degrees) is on the Moon's centre when the mount points there; far off
/// otherwise.
private func aimAt(
    _ mount: MountSession, targetAz: Double, targetAlt: Double
) -> @Sendable () -> (x: Double, y: Double) {
    { [weak mount] in
        guard let p = try? mount?.status().positionsDeg else { return (1e6, 1e6) }
        let dAz = wrap180(p[0] - targetAz) * cos(targetAlt * .pi / 180) * 3600
        let dAlt = (p[1] - targetAlt) * 3600
        return (dAz, dAlt)
    }
}

private func simulatedSession(
    _ camera: FakeCamera, setReference: Bool = true
) async throws -> (MountSession, MosaicSession) {
    let mount = try MountSession(port: "simulate", safety: ["max_goto_deg": 1.0])
    for _ in 0..<60 where (try mount.status().positionsDeg) == nil {
        try await Task.sleep(for: .milliseconds(50))
    }
    // The caller ties the altitude encoder to the sky before searching (as the
    // app does from the rough spotting-scope aim); 45° keeps a small search
    // inside the altitude envelope. A search can set it itself instead, which
    // `setReference: false` leaves to it.
    if setReference { try mount.setAltitudeReference(45) }
    var settings = MosaicSettings(site: Site(latitudeDeg: 40, longitudeDeg: -100))
    settings.settleSeconds = 0.02
    let session = MosaicSession(
        mount: mount, camera: camera, settings: settings, clock: { Date() }, onEvent: { _ in })
    return (mount, session)
}

/// The spiral drive hunts down a small bright target on the simulated mount
/// and stops with it centred, then leaves the mount disarmed.
@Test(.timeLimit(.minutes(3)))
func aSpiralSearchFindsABrightTargetOnTheSimulator() async throws {
    // A small target (radius 200″) in a tight field, so it must be hunted.
    let camera = FakeCamera(
        width: 320, height: 240, scale: 1.0, rotationDeg: 0, moonRadiusArcsec: 200)
    let (mount, session) = try await simulatedSession(camera)
    let start = try #require(try mount.status().positionsDeg)
    let targetAz = start[0] + 0.2
    let targetAlt = start[1]
    camera.provider = aimAt(mount, targetAz: targetAz, targetAlt: targetAlt)

    let outcome = try await session.searchSpiral(
        stepDeg: 0.1, reachDeg: 0.3,
        found: { ($0?.peak ?? 0) >= 120 && ($0?.brightFraction ?? 0) > 0.15 })

    #expect(outcome.found)
    #expect(outcome.stops > 1, "should have moved to find it, not found at the start")
    let at = try #require(outcome.atAzAltDeg)
    #expect(abs(wrap180(at[0] - targetAz)) < 0.12, "az \(at[0]) vs \(targetAz)")
    #expect(abs(at[1] - targetAlt) < 0.12, "alt \(at[1]) vs \(targetAlt)")
    // A step arms only for its own moves and disarms after.
    #expect(try mount.status().state == "ConnectedReadOnly")
}

/// "I see it" (the `cancelled` flag) ends the search promptly, between stops.
@Test(.timeLimit(.minutes(2)))
func cancellingStopsTheSearchBetweenStops() async throws {
    // Nothing is ever in view; only the cancel ends it.
    let camera = FakeCamera(width: 320, height: 240, scale: 1.0, moonRadiusArcsec: 200)
    let (_, session) = try await simulatedSession(camera)
    camera.provider = { (1e6, 1e6) }

    let checks = Counter()
    let outcome = try await session.searchSpiral(
        stepDeg: 0.1, reachDeg: 0.5,
        found: { _ in false },
        cancelled: { checks.next() > 2 })  // true on the 3rd check: after 2 stops

    #expect(!outcome.found)
    #expect(outcome.stops == 2, "cancelled after two stops, got \(outcome.stops)")
}

/// The raster drive also finds the target (a wide, short sweep).
@Test(.timeLimit(.minutes(3)))
func aRasterSearchFindsABrightTargetOnTheSimulator() async throws {
    let camera = FakeCamera(
        width: 320, height: 240, scale: 1.0, rotationDeg: 0, moonRadiusArcsec: 200)
    let (mount, session) = try await simulatedSession(camera)
    let start = try #require(try mount.status().positionsDeg)
    let targetAz = start[0] + 0.2
    let targetAlt = start[1]
    camera.provider = aimAt(mount, targetAz: targetAz, targetAlt: targetAlt)

    let outcome = try await session.searchRaster(
        halfWidthDeg: 0.3, halfHeightDeg: 0.1, rowSpacingDeg: 0.1, captureStepDeg: 0.1,
        found: { ($0?.peak ?? 0) >= 120 && ($0?.brightFraction ?? 0) > 0.15 })

    #expect(outcome.found)
    let at = try #require(outcome.atAzAltDeg)
    #expect(abs(wrap180(at[0] - targetAz)) < 0.12, "az \(at[0]) vs \(targetAz)")
}

/// A search with no altitude reference set yet ties the encoder to the sky
/// from the given reference before arming (the app passes the rough aim), so
/// it can run before Here.
@Test(.timeLimit(.minutes(3)))
func aSearchSetsTheAltitudeReferenceWhenNoneIsSet() async throws {
    let camera = FakeCamera(
        width: 320, height: 240, scale: 1.0, rotationDeg: 0, moonRadiusArcsec: 200)
    let (mount, session) = try await simulatedSession(camera, setReference: false)
    #expect(try mount.status().altitudeDeg == nil, "no reference to begin with")
    let start = try #require(try mount.status().positionsDeg)
    let targetAz = start[0] + 0.2
    camera.provider = aimAt(mount, targetAz: targetAz, targetAlt: start[1])

    let outcome = try await session.searchSpiral(
        stepDeg: 0.1, reachDeg: 0.3, referenceAltitudeDeg: 45,
        found: { ($0?.peak ?? 0) >= 120 && ($0?.brightFraction ?? 0) > 0.15 })

    #expect(outcome.found)
    #expect(try mount.status().altitudeDeg != nil, "the search set the reference")
}

/// Click-to-recentre: a point below the frame's centre (image y down) moves
/// the tube down by the pixel offset at the focal-length scale, azimuth held.
@Test(.timeLimit(.minutes(2)))
func recentreSlewsTheClickedPointTowardTheCentre() async throws {
    let camera = FakeCamera(width: 320, height: 240, scale: 1.0, moonRadiusArcsec: 200)
    let (mount, session) = try await simulatedSession(camera)
    let before = try #require(try mount.status().positionsDeg)

    try await session.recentre(pixelOffset: PixelOffset(x: 0, y: 200))

    let after = try #require(try mount.status().positionsDeg)
    let arcsecPerPixel = 206.265 * camera.info.pixelSizeUm / 2000  // no calibration yet
    let expectedAltDrop = 200 * arcsecPerPixel / 3600
    // The raw encoder angle wraps (0° → ~360°), so compare the wrapped delta.
    let altDelta = wrap180(after[1] - before[1])
    #expect(altDelta < 0, "altitude should drop: delta \(altDelta)")
    #expect(abs(altDelta + expectedAltDrop) < 0.005, "alt delta \(altDelta) vs -\(expectedAltDrop)")
    #expect(abs(wrap180(after[0] - before[0])) < 0.01, "azimuth should hold")
    #expect(try mount.status().state == "ConnectedReadOnly")
}
