import Foundation
import Testing

@testable import MoonMosaicCore

/// Fault injection on the simulated mount: a runaway turns the axis on its
/// own, as a stuck hand-controller key would.
@Test(.timeLimit(.minutes(1)))
func aRunawayTurnsTheAxis() async throws {
    let mount = try MountSession(port: "simulate")
    var start: [Double]?
    for _ in 0..<100 {
        if let p = try mount.status().positionsDeg { start = p; break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let p0 = try #require(start)
    try mount.inject(.runaway(.azimuth, degS: 1.0, seconds: 1.5))
    try await Task.sleep(for: .seconds(4.5))
    let p1 = try #require(try mount.status().positionsDeg)
    let moved = wrap180(p1[0] - p0[0])
    #expect(moved > 0.8 && moved < 2.5, "moved \(moved)°")
    #expect(abs(p1[1] - p0[1]) < 0.05)
    try mount.inject(.clear)
}
