import Foundation
import Testing

@testable import MoonMosaicCore

/// Polls status until `done` holds or `seconds` pass.
private func wait(
    _ session: MountSession, seconds: Double, until done: (MountSession.Status) -> Bool
) throws -> MountSession.Status {
    let end = Date().addingTimeInterval(seconds)
    while true {
        let s = try session.status()
        if done(s) || Date() > end { return s }
        Thread.sleep(forTimeInterval: 0.02)
    }
}

@Test func aGotoRunsOnTheSimulatedMountThroughTheRustAdapter() throws {
    let session = try MountSession(port: "simulate", safety: ["max_goto_deg": 0.5])
    #expect(session.opened.simulated)
    #expect(session.opened.model?.contains("Evolution") == true)
    _ = try wait(session, seconds: 2) { $0.positionsDeg != nil }

    // Arming needs the altitude reference.
    Thread.sleep(forTimeInterval: 0.6)
    #expect(throws: MountSession.Failure.self) { try session.arm() }
    try session.setAltitudeReference(30)
    Thread.sleep(forTimeInterval: 0.6)
    try session.arm()
    #expect(abs((try session.status().altitudeDeg ?? 0) - 30) < 0.01)

    let start = try #require(try session.status().positionsDeg)[1]
    try session.goto(.altitude, by: 0.05, approach: .positive)
    let done = try wait(session, seconds: 8) {
        $0.state == "Armed" && $0.lastRecord?.lastStage == "completed"
    }
    #expect(done.state == "Armed")
    #expect(done.lastFault == nil)
    let moved = try wait(session, seconds: 1) {
        abs(($0.positionsDeg?[1] ?? 0) - start - 0.05) < 0.001
    }
    #expect(abs(try #require(moved.positionsDeg)[1] - start - 0.05) < 0.001)
    #expect(abs((moved.altitudeDeg ?? 0) - 30.05) < 0.002)
}

@Test func refusalsComeBackAsErrors() throws {
    let session = try MountSession(port: "simulate")
    _ = try wait(session, seconds: 2) { $0.positionsDeg != nil }
    // Not armed: the goto is refused, with the controller's reason.
    do {
        try session.goto(.azimuth, by: 0.01)
        Issue.record("expected a refusal")
    } catch let failure as MountSession.Failure {
        #expect(failure.description.contains("Armed") || failure.description.contains("arm"))
    }
}
