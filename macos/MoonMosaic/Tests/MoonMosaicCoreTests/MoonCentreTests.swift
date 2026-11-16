import Foundation
import Testing

@testable import MoonMosaicCore

/// Cells over a survey: a disk of `r` at `centre`, lit beyond the terminator
/// for elongation `e` with the Sun along +x, earthshine `shine` (0 to 1) on
/// the dark side, sky 10.
private func survey(
    centre: SkyOffset, r: Double = 930, e: Double, shine: Double, reach: Double = 1.5 * 930,
    cell: Double = 24
) -> [MoonCentre.Sample] {
    var out: [MoonCentre.Sample] = []
    let n = Int(reach / cell)
    let (se, ce) = (sin(e * .pi / 180), cos(e * .pi / 180))
    for i in -n...n {
        for j in -n...n {
            let p = SkyOffset(x: Double(i) * cell, y: Double(j) * cell)
            guard hypot(p.x, p.y) <= reach else { continue }
            let (dx, dy) = (p.x - centre.x, p.y - centre.y)
            let d2 = dx * dx + dy * dy
            var mean = 10.0
            if d2 < r * r {
                let z = (1 - d2 / (r * r)).squareRoot()
                mean = dx / r * se - z * ce > 0 ? 255 : 10 + 40 * shine
            }
            out.append(MoonCentre.Sample(sky: p, mean: mean))
        }
    }
    return out
}

@Test(arguments: [
    (e: 180.0, shine: 0.0, label: "full"),
    (e: 53.0, shine: 1.0, label: "crescent with earthshine"),
    (e: 53.0, shine: 0.0, label: "crescent, no earthshine"),
    (e: 90.0, shine: 0.0, label: "half"),
    (e: 120.0, shine: 0.0, label: "gibbous"),
])
func theFitFindsTheCentreAtAnyPhase(_ c: (e: Double, shine: Double, label: String)) throws {
    // Here on the lit part, well off the centre.
    let truth = SkyOffset(x: -520, y: 140)
    let fit = try #require(
        MoonCentre.fit(survey(centre: truth, e: c.e, shine: c.shine), radiusArcsec: 930,
            searchArcsec: 1.1 * 930), "\(c.label)")
    #expect(
        hypot(fit.centre.x - truth.x, fit.centre.y - truth.y) < 20,
        "\(c.label): found \(fit.centre), truth \(truth)")
    #expect(fit.agreement > 0.95, "\(c.label): \(fit.agreement)")
    if c.e < 180 { #expect(fit.earthshine == (c.shine > 0), "\(c.label)") }
}

@Test func noLitCellsGivesNoFit() {
    let sky = (0..<100).map { MoonCentre.Sample(sky: SkyOffset(x: Double($0), y: 0), mean: 10) }
    #expect(MoonCentre.fit(sky, radiusArcsec: 930, searchArcsec: 1000) == nil)
}

@Test func tilesAreLitWhereTheSurveySawSunlight() throws {
    let cal = CameraCalibration(a: -1, b: 0, c: 0, d: 1)
    let plan = MosaicPlanner.plan(
        moonDiameterDeg: 1860 / 3600, calibration: cal, frameWidth: 640, frameHeight: 360)
    // Sunlight only far along +x on the sky.
    let lit = stride(from: 700.0, to: 930, by: 20).flatMap { x in
        stride(from: -200.0, to: 200, by: 20).map { SkyOffset(x: x, y: $0) }
    }
    let marked = MosaicPlanner.markLit(plan, litSky: lit, calibration: cal)
    let litTiles = marked.tiles.filter(\.lit)
    #expect(!litTiles.isEmpty && litTiles.count < marked.tiles.count / 3)
    // Sky +x shows at image +x with this calibration (−M·s, M = diag(−1, 1)).
    #expect(litTiles.allSatisfy { $0.center.x > 0 })
}

/// A moment when the Moon is high above `site` and well away from the Sun.
private func moonUp(over site: Site) throws -> Date {
    var t = Date(timeIntervalSince1970: 1_793_491_200)  // 2026-11-01 00:00 UTC
    for _ in 0..<(24 * 30) {
        let moon = Ephemeris.moon(at: t, from: site).horizontal
        let separation = Ephemeris.separationDeg(
            Ephemeris.sun(at: t), Ephemeris.moon(at: t).equatorial)
        if moon.altDeg > 35, separation > 60 { return t }
        t.addTimeInterval(3_600)
    }
    throw MosaicError(description: "no suitable moment found")
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// On the simulated mount, a 20% crescent with Here pressed on its lit part,
/// well off the centre: the survey finds the centre, the plan keeps the lit
/// tiles, and a lit tile is captured where it was planned on the real Moon.
@Test(.timeLimit(.minutes(10)))
func theSurveyRecentresHereOnACrescent() async throws {
    let site = Site(latitudeDeg: 40, longitudeDeg: -100)
    let epoch = try moonUp(over: site)
    let started = Date()
    let clock: @Sendable () -> Date = {
        epoch.addingTimeInterval(Date().timeIntervalSince(started))
    }
    let mount = try MountSession(port: "simulate", safety: ["max_goto_deg": 1.0])
    // A big field (640″ × 360″) keeps the survey short in the test.
    let radius = Ephemeris.moon(at: epoch, from: site).diameterDeg * 1800
    let camera = FakeCamera(
        width: 640, height: 360, scale: 1.0, rotationDeg: 25, moonRadiusArcsec: radius)
    camera.elongationDeg = 53
    camera.sunDirectionDeg = 200
    camera.earthshine = 0.0006
    var settings = MosaicSettings(site: site)
    settings.videoSeconds = 0.4
    settings.settleSeconds = 0.2
    settings.focalLengthMm = 600
    let session = MosaicSession(
        mount: mount, camera: camera, settings: settings, clock: clock,
        onEvent: { if case .message(let m) = $0 { print("EVENT \(m)") } })
    // Here is pressed with the camera on this part of the Moon: on the lit
    // crescent, 650″ from the centre towards the Sun.
    let a = 200.0 * .pi / 180
    let hereOnMoon = (x: 650 * cos(a), y: 650 * sin(a))
    let firstHere = Box<Here?>(nil)
    camera.provider = { [weak session] in
        guard let session, let here = firstHere.value,
            let p = try? session.mount.status().positionsDeg
        else { return hereOnMoon }
        let m = session.relativeMove(
            from: (here.time, [here.azimuthDeg, here.altitudeDeg]), to: (clock(), p))
        return (m.x + hereOnMoon.x, m.y + hereOnMoon.y)
    }
    for _ in 0..<50 where try mount.status().positionsDeg == nil {
        try await Task.sleep(for: .milliseconds(50))
    }
    try await Task.sleep(for: .milliseconds(600))

    try await session.markHere()
    firstHere.value = session.here
    try await session.calibrate()
    let fit = try await session.findCentre()
    // The centre is −hereOnMoon from Here.
    #expect(
        hypot(fit.centre.x + hereOnMoon.x, fit.centre.y + hereOnMoon.y) < 30,
        "found \(fit.centre), truth \((-hereOnMoon.x, -hereOnMoon.y))")
    #expect(fit.earthshine)
    #expect(try mount.status().state == "ConnectedReadOnly")

    let plan = try session.makePlan()
    let lit = plan.tiles.filter(\.lit)
    #expect(!lit.isEmpty && lit.count < plan.tiles.count)
    #expect(session.darkTilesToDo.count == plan.tiles.count - lit.count)
    // Capture the lit tile furthest towards the Sun: where it really points.
    let sunward = try #require(
        lit.max { ($0.pointing.x * cos(a) + $0.pointing.y * sin(a)) < ($1.pointing.x * cos(a) + $1.pointing.y * sin(a)) })
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "moonmosaic-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    let before = camera.history.count
    try await session.run(tiles: [sunward.id], into: folder)
    let during = camera.history[before...]
    let mid = try #require(during.dropFirst(during.count / 2).first)
    #expect(
        // The aim's own tolerance, plus the centre's error allowed above.
        hypot(mid.x - sunward.pointing.x, mid.y - sunward.pointing.y) < 0.1 * 360 + 30,
        "at \(mid), planned \(sunward.pointing)")
}
