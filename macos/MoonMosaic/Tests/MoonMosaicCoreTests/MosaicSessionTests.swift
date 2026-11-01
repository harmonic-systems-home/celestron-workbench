import Foundation
import Testing

@testable import MoonMosaicCore

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

/// The whole workflow on the simulated mount: Here, calibration, a plan, and
/// three tiles captured, each pointing where it was planned.
@Test(.timeLimit(.minutes(3)))
func aMosaicRunsOnTheSimulatedMount() async throws {
    let site = Site(latitudeDeg: 40, longitudeDeg: -100)
    let epoch = try moonUp(over: site)
    let started = Date()
    let clock: @Sendable () -> Date = {
        epoch.addingTimeInterval(Date().timeIntervalSince(started))
    }

    let mount = try MountSession(port: "simulate", safety: ["max_goto_deg": 1.0])
    let camera = FakeCamera(width: 640, height: 360, scale: 0.3, rotationDeg: 20)
    var settings = MosaicSettings(site: site)
    settings.videoSeconds = 0.4
    settings.settleSeconds = 0.3
    let session = MosaicSession(
        mount: mount, camera: camera, settings: settings, clock: clock,
        onEvent: { if case .message(let m) = $0 { print("EVENT \(m)") } })
    // The fake camera sees the Moon from wherever the simulated mount points.
    camera.provider = { [weak session] in
        guard let session, let here = session.here,
            let p = try? session.mount.status().positionsDeg
        else { return (0, 0) }
        return session.relativeMove(
            from: (here.time, [here.azimuthDeg, here.altitudeDeg]), to: (clock(), p)
        ).tuple
    }
    for _ in 0..<50 where try mount.status().positionsDeg == nil {
        try await Task.sleep(for: .milliseconds(50))
    }
    try await Task.sleep(for: .milliseconds(600))

    try await session.markHere()
    // Steps arm the mount for their own moves only, leaving the keys free.
    #expect(try mount.status().state == "ConnectedReadOnly")
    try await session.calibrate()
    #expect(try mount.status().state == "ConnectedReadOnly")
    let cal = try #require(session.calibration)
    #expect(abs(cal.arcsecPerPixel - 0.3) < 0.01, "\(cal.arcsecPerPixel)″/px")

    let plan = try session.makePlan()
    let middle = plan.tiles.sorted {
        hypot($0.center.x, $0.center.y) < hypot($1.center.x, $1.center.y)
    }.prefix(3).map(\.id)
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent(
        "moonmosaic-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: folder) }
    for id in middle {
        let before = camera.history.count
        try await session.run(tiles: [id], into: folder)
        let during = camera.history[before...]
        guard case .done(let file, let frames, _) = session.states[id] else {
            Issue.record("tile \(id): \(String(describing: session.states[id]))")
            continue
        }
        #expect(frames > 0)
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(file).path))
        // Where the camera pointed in the middle of the video, against the
        // plan: within a tenth of the frame's short side (the field is
        // 192″ × 108″ here), well inside the 25% overlap.
        let tile = try #require(plan.tiles.first { $0.id == id })
        let mid = try #require(during.dropFirst(during.count / 2).first)
        #expect(
            hypot(mid.x - tile.pointing.x, mid.y - tile.pointing.y) < 0.1 * 108,
            "tile \(id): at \(mid), planned \(tile.pointing)")
        #expect(session.stacks[id]?.image() != nil)
        // What the log says the camera saw, against where it really pointed.
        let seen = cal.image(for: SkyOffset(x: mid.x, y: mid.y))
        let logged = try #require(try loggedTiles(in: folder)[id])
        #expect(
            hypot(logged.x + seen.x, logged.y + seen.y) < 20,
            "tile \(id): logged \(logged), camera saw \((-seen.x, -seen.y))")
    }
    // The plan, once, ahead of the tiles.
    let lines = try String(
        contentsOf: folder.appendingPathComponent(SessionLog.fileName), encoding: .utf8
    ).split(separator: "\n")
    let records = try lines.map {
        try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
    #expect(records.map { $0["type"] as? String } == ["plan"] + middle.map { _ in "tile" })
    #expect((records[0]["tiles"] as? [Any])?.count == plan.tiles.count)
}

/// Each done tile's measured centre from the session log, by id.
private func loggedTiles(in folder: URL) throws -> [Int: (x: Double, y: Double)] {
    let text = try String(
        contentsOf: folder.appendingPathComponent(SessionLog.fileName), encoding: .utf8)
    var out: [Int: (x: Double, y: Double)] = [:]
    for line in text.split(separator: "\n") {
        guard
            let r = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
            r["type"] as? String == "tile", let id = r["id"] as? Int,
            let m = r["measured"] as? [String: Double], let x = m["x"], let y = m["y"]
        else { continue }
        out[id] = (x, y)
    }
    return out
}

extension SkyOffset {
    fileprivate var tuple: (x: Double, y: Double) { (x, y) }
}
