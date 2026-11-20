import Foundation
import Testing

@testable import MoonMosaicCore

/// Calibration by drift and two tracked moves (ADR 0022 amendment 6), on the
/// simulated mount and fake camera, direct and mirrored (a star diagonal).
/// The fake camera's scale (0.6″/px) is twice the focal-length estimate,
/// as with a 2× Barlow: the drift must find it without being told.
@Test(.timeLimit(.minutes(4)), arguments: [false, true])
func calibrationFindsScaleTurnAndMirroringFromDrift(mirrored: Bool) async throws {
    let site = Site(latitudeDeg: 40, longitudeDeg: -100)
    var t = Date(timeIntervalSince1970: 1_793_491_200)
    for _ in 0..<(24 * 30) {
        let m = Ephemeris.moon(at: t, from: site).horizontal
        let sep = Ephemeris.separationDeg(Ephemeris.sun(at: t), Ephemeris.moon(at: t).equatorial)
        if m.altDeg > 35, sep > 60 { break }
        t.addTimeInterval(3600)
    }
    let epoch = t
    let started = Date()
    let clock: @Sendable () -> Date = { epoch.addingTimeInterval(Date().timeIntervalSince(started)) }
    let mount = try MountSession(port: "simulate", safety: ["max_goto_deg": 1.0])
    let camera = FakeCamera(width: 1280, height: 720, scale: 0.6, rotationDeg: 20, mirrored: mirrored)
    var settings = MosaicSettings(site: site)
    settings.settleSeconds = 0.3
    let session = MosaicSession(
        mount: mount, camera: camera, settings: settings, clock: clock, onEvent: { _ in })
    camera.provider = { [weak session] in
        guard let session, let here = session.here,
            let p = try? session.mount.status().positionsDeg
        else { return (0, 0) }
        let r = session.relativeMove(
            from: (here.time, [here.azimuthDeg, here.altitudeDeg]), to: (clock(), p))
        return (r.x, r.y)
    }
    for _ in 0..<50 where try mount.status().positionsDeg == nil {
        try await Task.sleep(for: .milliseconds(50))
    }
    try await Task.sleep(for: .milliseconds(600))
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cal-\(UUID())")
    defer { try? FileManager.default.removeItem(at: dir) }
    session.diagnostics = dir
    try await session.markHere()
    try await session.calibrate()
    let cal = try #require(session.calibration)
    #expect(abs(cal.arcsecPerPixel / 0.6 - 1) < 0.03, "\(cal.arcsecPerPixel)″/px")
    #expect(cal.mirrored == mirrored)
    // Everything it measured is kept for review.
    let records = try String(
        contentsOf: dir.appendingPathComponent("calibration/records.ndjson"), encoding: .utf8)
    #expect(records.contains("\"method\":\"drift+moves\""))
    #expect(try mount.status().lastFault == nil)
}
