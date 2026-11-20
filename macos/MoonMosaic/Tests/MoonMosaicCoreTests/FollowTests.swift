import Foundation
import Testing

@testable import MoonMosaicCore

/// Follow mode (ADR 0022 amendment 7) on the simulated mount: it tracks the
/// Moon from the ephemeris alone (no Here), a nudge moves the scope against
/// the Moon and stays, and Undo returns to where it was against the Moon.
@Test(.timeLimit(.minutes(2)))
func followTracksNudgesAndUndoes() async throws {
    let site = Site(latitudeDeg: 40, longitudeDeg: -100)
    var t = Date(timeIntervalSince1970: 1_793_491_200)
    for _ in 0..<(24 * 30) {
        if Ephemeris.moon(at: t, from: site).horizontal.altDeg > 35 { break }
        t.addTimeInterval(3600)
    }
    let epoch = t
    let started = Date()
    let clock: @Sendable () -> Date = { epoch.addingTimeInterval(Date().timeIntervalSince(started)) }
    let mount = try MountSession(port: "simulate", safety: ["max_goto_deg": 5.0])
    let session = MosaicSession(
        mount: mount, camera: FakeCamera(), settings: MosaicSettings(site: site), clock: clock,
        onEvent: { if case .message(let m) = $0 { print("EVENT \(m)") } })
    for _ in 0..<50 where try mount.status().positionsDeg == nil {
        try await Task.sleep(for: .milliseconds(50))
    }
    try mount.setAltitudeReference(Ephemeris.moon(at: clock(), from: site).horizontal.altDeg)
    final class Stop: @unchecked Sendable { var value = false }
    let stop = Stop()
    let loop = Task { try await session.runFollow(cancelled: { stop.value }) }
    defer { stop.value = true }

    func offsetNow() async throws -> FollowState.Offset {
        let p = try await session.freshPosition()
        return session.offset(of: p, at: clock())
    }
    func sky(_ a: FollowState.Offset, _ b: FollowState.Offset) -> (Double, Double) {
        let alt = Ephemeris.moon(at: clock(), from: site).horizontal.altDeg
        return (wrap180(a.az - b.az) * cos(alt * .pi / 180) * 3600, (a.alt - b.alt) * 3600)
    }

    try await Task.sleep(for: .seconds(2))
    let before = try await offsetNow()
    // Tracking: steady against the Moon.
    try await Task.sleep(for: .seconds(3))
    let still = sky(try await offsetNow(), before)
    #expect(hypot(still.0, still.1) < 15, "drifted \(still) in 3 s while tracking")

    // A nudge of 300″ along azimuth: it moves and stays.
    session.followNudge(SkyOffset(x: 300, y: 0))
    try await Task.sleep(for: .seconds(4))
    let moved = sky(try await offsetNow(), before)
    #expect(abs(moved.0 - 300) < 40 && abs(moved.1) < 40, "nudged \(moved)")
    #expect(session.follow.undoDepth == 1)

    // Undo: back to before the nudge, against the Moon.
    session.followUndo()
    for _ in 0..<100 {
        try await Task.sleep(for: .milliseconds(200))
        if session.follow.undoDepth == 0, !session.follow.nudging { break }
    }
    try await Task.sleep(for: .seconds(2))
    let back = sky(try await offsetNow(), before)
    #expect(hypot(back.0, back.1) < 30, "after Undo \(back)")
    stop.value = true
    _ = await loop.result
    try? mount.stopTracking()
}
