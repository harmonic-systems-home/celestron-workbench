import Foundation
import Testing

@testable import ImuLoggerCore

private func rotation(aboutZ angle: Double) -> Quaternion {
    Quaternion(w: cos(angle / 2), x: 0, y: 0, z: sin(angle / 2))
}

@Test func normalizationProducesUnitQuaternions() throws {
    let q = try #require(Quaternion(w: 2, x: 0, y: 0, z: 0).normalized())
    #expect(q == .identity)
    let r = try #require(Quaternion(w: 1, x: 2, y: 3, z: 4).normalized())
    #expect(abs(r.norm - 1) < 1e-12)
    #expect(Quaternion(w: 0, x: 0, y: 0, z: 0).normalized() == nil)
    #expect(Quaternion(w: .nan, x: 0, y: 0, z: 0).normalized() == nil)
}

@Test func angleHandlesSignEquivalence() throws {
    let q = rotation(aboutZ: 0.3)
    let negated = Quaternion(w: -q.w, x: -q.x, y: -q.y, z: -q.z)
    #expect(try #require(q.angle(to: negated)) < 1e-7)
    #expect(abs(try #require(Quaternion.identity.angle(to: q)) - 0.3) < 1e-12)
}

@Test func angleWrapsAcrossPi() throws {
    // 170° and -170° about the same axis are 20° apart, not 340°.
    let a = rotation(aboutZ: 170 * .pi / 180)
    let b = rotation(aboutZ: -170 * .pi / 180)
    #expect(abs(try #require(a.angle(to: b)) - 20 * .pi / 180) < 1e-9)
}

@Test func angleIgnoresNonUnitInputs() throws {
    let q = rotation(aboutZ: 0.5)
    let scaled = Quaternion(w: q.w * 3, x: q.x * 3, y: q.y * 3, z: q.z * 3)
    #expect(abs(try #require(Quaternion.identity.angle(to: scaled)) - 0.5) < 1e-12)
}

@Test func hamiltonProductComposesRotations() throws {
    let composed = rotation(aboutZ: 0.2) * rotation(aboutZ: 0.3)
    #expect(try #require(composed.angle(to: rotation(aboutZ: 0.5))) < 1e-7)
    let i = Quaternion(w: 0, x: 1, y: 0, z: 0)
    let j = Quaternion(w: 0, x: 0, y: 1, z: 0)
    #expect(i * j == Quaternion(w: 0, x: 0, y: 0, z: 1))  // ij = k
}

@Test func continuityMonitorFlagsUnexplainedJumpsOnly() {
    var monitor = AttitudeContinuityMonitor()
    let step: Nanos = 10_000_000  // 10 ms
    // Rotating at 1 rad/s: 0.01 rad per step is explained.
    var t: Nanos = 0
    var angle = 0.0
    for seq in 0..<50 {
        let s = motion(
            Seq(seq), tNs: t, attitude: rotation(aboutZ: angle), rate: Vec3(0, 0, 1))
        #expect(monitor.check(s) == nil)
        t += step
        angle += 0.01
    }
    // A reset to identity while barely rotating is not explained.
    let jump = monitor.check(
        motion(50, tNs: t, attitude: .identity, rate: Vec3(0, 0, 0.001)))
    #expect(jump != nil)
    #expect(jump?.seq == 50)
    // Time going backwards is always a discontinuity.
    #expect(monitor.check(motion(51, tNs: t - step, attitude: .identity)) != nil)
}
