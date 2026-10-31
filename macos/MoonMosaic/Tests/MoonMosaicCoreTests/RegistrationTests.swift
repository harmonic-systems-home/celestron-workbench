import Foundation
import Testing

@testable import MoonMosaicCore

/// Moving the pointing moves the image by a known amount; registration
/// finds it to well under a pixel.
@Test func registrationFindsAKnownShift() throws {
    let camera = FakeCamera(scale: 0.6, rotationDeg: 0)
    camera.pointing = (100, -50)
    let a = try #require(try camera.frame(timeoutMs: 0))
    // 30″ along x and 18″ along y: 50 and 30 pixels at 0.6″/px.
    camera.pointing = (130, -32)
    let b = try #require(try camera.frame(timeoutMs: 0))
    let s = Registration.shift(from: a, to: b)
    // Pointing right moves the scene left; pointing up (+y) moves it down (+v).
    #expect(abs(s.dx - -50) < 0.5, "dx \(s.dx) dy \(s.dy) peak \(s.peak)")
    #expect(abs(s.dy - 30) < 0.5, "\(s)")
}

@Test func registrationOfAFrameWithItselfIsZero() throws {
    let camera = FakeCamera()
    let a = try #require(try camera.frame(timeoutMs: 0))
    let s = Registration.shift(from: a, to: a)
    #expect(abs(s.dx) < 0.1 && abs(s.dy) < 0.1, "\(s)")
}

/// Full-size frames (as the ASI662MC gives): the shift is found and the
/// match is strong, whatever the frame size.
@Test func fullSizeFramesRegisterWithAStrongPeak() throws {
    let camera = FakeCamera(width: 1920, height: 1080, scale: 0.3, rotationDeg: 25)
    let a = try #require(try camera.frame(timeoutMs: 0))
    camera.pointing = (65, 0)
    let b = try #require(try camera.frame(timeoutMs: 0))
    let s = Registration.shift(from: a, to: b)
    let t = 25 * Double.pi / 180
    #expect(abs(s.dx - -65 / 0.3 * cos(t)) < 0.5, "\(s)")
    #expect(abs(s.dy - 65 / 0.3 * sin(t)) < 0.5, "\(s)")
    #expect(s.peak > 0.3, "peak \(s.peak)")
}
