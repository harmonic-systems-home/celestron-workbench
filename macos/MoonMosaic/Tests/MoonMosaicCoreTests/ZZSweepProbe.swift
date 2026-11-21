import Foundation
import Testing

@testable import MoonMosaicCore

/// The sweep search (ADR 0022 amendment 7) on the simulated mount and
/// camera: rows as single moves with the video watched, the Moon out of view
/// at the start, found and stepped onto, riding on the Moon's motion.
@Test(.timeLimit(.minutes(2)))  // the moves wait out the mount's coast now
func zzProbeSweepExtent() async throws {
    let site = Site(latitudeDeg: 40, longitudeDeg: -100)
    var t = Date(timeIntervalSince1970: 1_793_491_200)
    for _ in 0..<(24 * 30) {
        if Ephemeris.moon(at: t, from: site).horizontal.altDeg > 35 { break }
        t.addTimeInterval(3600)
    }
    let epoch = t
    let started = Date()
    let clock: @Sendable () -> Date = { epoch.addingTimeInterval(Date().timeIntervalSince(started)) }
    let mount = try MountSession(port: "simulate", safety: ["max_goto_deg": 10.0])
    try mount.setSimSpeed(5)
    let camera = SimCamera(
        optics: SimOptics(focalLengthMm: 2032, sensor: .testMono), scene: MoonScene.synthetic(size: 768, phaseAngleDeg: 50))
    var settings = MosaicSettings(site: site)
    settings.focalLengthMm = 2032
    settings.settleSeconds = 0.2
    let session = MosaicSession(
        mount: mount, camera: camera, settings: settings, clock: clock,
        onEvent: { if case .message(let m) = $0 { print("EVENT \(m)") } })
    for _ in 0..<50 where try mount.status().positionsDeg == nil {
        try await Task.sleep(for: .milliseconds(50))
    }
    try mount.setAltitudeReference(Ephemeris.moon(at: clock(), from: site).horizontal.altDeg)
    // The Moon sits 0.9° right and 0.45° up of where the scope starts.
    let p0 = try await session.freshPosition()
    let o0 = session.offset(of: p0, at: clock())
    camera.provider = { [weak session] in
        guard let session, let st = try? session.mount.status(), var p = st.positionsDeg else { return (1e6, 1e6) }
        if let r = st.tracking, let age = st.positionsAgeMs { p = [p[0] + r[0] * Double(age) / 1000, p[1] + r[1] * Double(age) / 1000] }
        let o = session.offset(of: p, at: clock())
        let alt = Ephemeris.moon(at: clock(), from: site).horizontal.altDeg
        return (
            (wrap180(o.az - o0.az) * cos(alt * .pi / 180) - 0.9) * 3600, (o.alt - o0.alt - 5) * 3600
        )
    }
    let t0 = Date()
    let startTruth = camera.pointing
    let outcome = try await session.searchSweep(
        halfWidthDeg: 2, halfHeightDeg: 1.2, converge: MosaicSession.Converge(),
        found: { Blob.looksLikeMoon($0) })
    let ended = camera.pointing
    let xs = camera.history.map { $0.x - startTruth.x }
    let alt = Ephemeris.moon(at: clock(), from: site).horizontal.altDeg
    print("PROBE alt \(alt) start \(startTruth) x range \(xs.min()! / 3600)…\(xs.max()! / 3600) deg (expect ±2)")
    try? mount.stopTracking()
    let took = Date().timeIntervalSince(t0)
    print("SWEEP took \(Int(took)) s, \(outcome.stops) rows, converged \(outcome.converged)")
    #expect(outcome.found)
    #expect(outcome.converged)
    let p = ended
    #expect(hypot(p.x, p.y) < 600, "ended \(p) from the Moon's centre")
}
