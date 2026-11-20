import Foundation
import Testing

@testable import MoonMosaicCore

/// Orient Camera (ADR 0022 amendment 7) on the simulated mount and camera:
/// a drift gives the scale and turn, one nudge across it settles mirroring.
/// No Here is needed. Checked against the simulated camera's true mapping.
@Test(.timeLimit(.minutes(3)), arguments: [(0.0, true), (137.0, false), (250.0, true)])
func orientCameraFindsScaleTurnAndMirroring(turn: Double, diagonal: Bool) async throws {
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
    var optics = SimOptics(focalLengthMm: 600, sensor: .testMono)
    optics.cameraRotationDeg = turn
    optics.diagonal = diagonal
    let camera = SimCamera(optics: optics, scene: MoonScene.synthetic(size: 768, phaseAngleDeg: 40))
    var c = SimCamera.Conditions()
    c.seeingArcsec = 1
    camera.conditions = c
    var settings = MosaicSettings(site: site)
    settings.focalLengthMm = 600
    let session = MosaicSession(
        mount: mount, camera: camera, settings: settings, clock: clock,
        onEvent: { if case .message(let m) = $0 { print("EVENT \(m)") } })
    for _ in 0..<50 where try mount.status().positionsDeg == nil {
        try await Task.sleep(for: .milliseconds(50))
    }
    try mount.setAltitudeReference(Ephemeris.moon(at: clock(), from: site).horizontal.altDeg)
    // The camera starts on textured Moon, 300″ left and 100″ up of the centre.
    let p0 = try await session.freshPosition()
    let o0 = session.offset(of: p0, at: clock())
    camera.provider = { [weak session] in
        guard let session, let p = try? session.mount.status().positionsDeg else { return (0, 0) }
        let o = session.offset(of: p, at: clock())
        let alt = Ephemeris.moon(at: clock(), from: site).horizontal.altDeg
        return (
            -300 + wrap180(o.az - o0.az) * cos(alt * .pi / 180) * 3600, 100 + (o.alt - o0.alt) * 3600
        )
    }
    let result = try await session.orientCamera()
    try? mount.stopTracking()
    // The true map: a pointing change d shifts the content by −A⁻¹ d.
    let o = camera.sky(u: 0, v: 0, pointing: (0, 0))
    let ex = camera.sky(u: 1, v: 0, pointing: (0, 0))
    let ey = camera.sky(u: 0, v: 1, pointing: (0, 0))
    let (a, b, cc, d) = (ex.x - o.x, ey.x - o.x, ex.y - o.y, ey.y - o.y)
    let det = a * d - b * cc
    for s in [SkyOffset(x: 100, y: 0), SkyOffset(x: 0, y: 100)] {
        let truth = ((-s.x * d + s.y * b) / det, (-s.y * a + s.x * cc) / det)
        let got = result.calibration.image(for: s)
        let err = hypot(got.x - truth.0, got.y - truth.1) / hypot(truth.0, truth.1)
        #expect(err < 0.05, "for \(s): got \(got), true \(truth)")
    }
}
