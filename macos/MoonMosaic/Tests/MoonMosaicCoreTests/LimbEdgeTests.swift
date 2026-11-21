import Foundation
import Testing

@testable import MoonMosaicCore

/// Orient Moon's limb probe: edges and the circle through them.

/// A frame of a bright disk (sky offset `centre`, radius `r`″) with a glow
/// fading outside it, as the camera at `pointing` sees it through `m`.
private func diskFrame(
    centre: SkyOffset, r: Double, pointing: SkyOffset, m: CameraCalibration, width: Int = 960, height: Int = 540
) -> Frame {
    var px = [UInt8](repeating: 0, count: width * height)
    for y in 0..<height {
        for x in 0..<width {
            let u = PixelOffset(x: Double(x) + 0.5 - Double(width) / 2, y: Double(y) + 0.5 - Double(height) / 2)
            let d = m.sky(for: u)
            let s = SkyOffset(x: pointing.x - d.x, y: pointing.y - d.y)
            let dist = hypot(s.x - centre.x, s.y - centre.y)
            // The limb blurred over ~2″; outside, glow fading over ~60″.
            let edge = 1 / (1 + exp((dist - r) / 0.8))
            let glow = dist > r ? 25 * exp(-(dist - r) / 60) : 0
            let v = 5 + 190 * edge + glow + Double((x * 7 + y * 13) % 5)
            px[y * width + x] = UInt8(min(255, max(0, v)))
        }
    }
    return Frame(width: width, height: height, pixels: px, time: Date())
}

@Test func limbCircleComesFromTheSharpEdgeNotTheGlow() throws {
    // 0.56″ a pixel, turned 20° and mirrored.
    let k = 1 / 0.56
    let t = 20 * Double.pi / 180
    let m = CameraCalibration(a: k * cos(t), b: k * sin(t), c: k * sin(t), d: -k * cos(t))
    let centre = SkyOffset(x: -640, y: -490)
    let r = 963.0
    var all: [LimbEdge.Point] = []
    for turnDeg in [150.0, 85.0, 215.0] {
        let a = turnDeg * .pi / 180
        let e = SkyOffset(x: sin(a), y: cos(a))
        // Pointing a little inside the limb, as after a probe's crossing.
        let p = SkyOffset(x: centre.x + e.x * (r - 40), y: centre.y + e.y * (r - 40))
        let f = diskFrame(centre: centre, r: r, pointing: p, m: m)
        let pts = LimbEdge.points(f, pointing: p, calibration: m, outward: e)
        #expect(pts.count > 30, "\(pts.count) points at \(turnDeg)°")
        all += pts
    }
    let c = try #require(LimbEdge.fit(all, radius: r, start: SkyOffset(x: -500, y: -600)))
    #expect(hypot(c.centre.x - centre.x, c.centre.y - centre.y) < 4, "\(c)")
    #expect(abs(c.freeRadius / r - 1) < 0.01, "\(c)")
}

/// A real survey's frames, replayed through the limb edge (only when
/// MOSAIC_LIMB_SURVEY names a survey folder and MOSAIC_LIMB_CAL its
/// calibration "a,b,c,d"; real data never lives in the repo).
@Test func limbEdgeOnARealSurvey() throws {
    let env = ProcessInfo.processInfo.environment
    guard let dir = env["MOSAIC_LIMB_SURVEY"], let cal = env["MOSAIC_LIMB_CAL"] else { return }
    let v = cal.split(separator: ",").compactMap { Double($0) }
    let m = CameraCalibration(a: v[0], b: v[1], c: v[2], d: v[3])
    let r = Double(env["MOSAIC_LIMB_RADIUS"] ?? "964") ?? 964
    let records = try String(contentsOfFile: dir + "/records.ndjson", encoding: .utf8)
        .split(separator: "\n").compactMap {
            try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
        }
    var all: [LimbEdge.Point] = []
    var guesses: [SkyOffset] = []
    for rec in records {
        guard let stop = rec["stop"] as? Int, let time = rec["time"] as? String,
            let p = rec["pointing"] as? [Double]
        else { continue }
        let data = try Data(contentsOf: URL(fileURLWithPath: String(format: "%@/%@-%02d.pgm", dir, time, stop)))
        let px = [UInt8](data.suffix(1920 * 1080))
        let f = Frame(width: 1920, height: 1080, pixels: px, time: Date())
        let pts = LimbEdge.points(f, pointing: SkyOffset(x: p[0], y: p[1]), calibration: m)
        if pts.count > 30 {
            // A rough guess: the edge's mean, a radius in from its sky side.
            let mx = pts.map(\.sky.x).reduce(0, +) / Double(pts.count)
            let my = pts.map(\.sky.y).reduce(0, +) / Double(pts.count)
            let ox = pts.map(\.outward.x).reduce(0, +) / Double(pts.count)
            let oy = pts.map(\.outward.y).reduce(0, +) / Double(pts.count)
            let n = max(1e-9, hypot(ox, oy))
            guesses.append(SkyOffset(x: mx - ox / n * r, y: my - oy / n * r))
        }
        print("stop \(stop): \(pts.count) edge points")
        all += pts
    }
    let g = SkyOffset(
        x: guesses.map(\.x).reduce(0, +) / Double(max(1, guesses.count)),
        y: guesses.map(\.y).reduce(0, +) / Double(max(1, guesses.count)))
    let c = try #require(LimbEdge.fit(all, radius: r, start: g))
    print(
        String(
            format: "LIMB centre (%.0f, %.0f), %d of %d inliers, rms %.1f″, free radius %.0f″ (start %.0f, %.0f)",
            c.centre.x, c.centre.y, c.inliers, c.total, c.rms, c.freeRadius, g.x, g.y))
}

@Test func driftCorrectionStaysContinuousAsItIsRefined() {
    let d = MoonModelDrift()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    #expect(d.bias(at: t0) == (az: 0, alt: 0))
    d.addRate((az: 0.001, alt: -0.0005), at: t0)
    let t1 = t0.addingTimeInterval(100)
    let b1 = d.bias(at: t1)
    #expect(abs(b1.az - 0.1) < 1e-9 && abs(b1.alt + 0.05) < 1e-9)
    // A refinement at t1: no jump there, the new rate after.
    d.addRate((az: -0.0004, alt: 0), at: t1)
    let b1b = d.bias(at: t1)
    #expect(abs(b1b.az - b1.az) < 1e-12 && abs(b1b.alt - b1.alt) < 1e-12)
    let b2 = d.bias(at: t1.addingTimeInterval(10))
    #expect(abs(b2.az - (0.1 + 0.006)) < 1e-9)
    #expect(d.measured == t1)
}

@Test func driftRefinementDoesNotReachBackPastItsMoment() {
    let d = MoonModelDrift()
    let t0 = Date(timeIntervalSince1970: 1_000_000)
    d.addRate((az: 0.001, alt: 0), at: t0)
    let here = t0.addingTimeInterval(-50)  // Here was pressed before the first measurement
    #expect(abs(d.bias(at: here).az + 0.05) < 1e-9)  // the first rate runs back to it
    let t1 = t0.addingTimeInterval(100)
    d.addRate((az: 0.002, alt: 0), at: t1)
    #expect(abs(d.bias(at: here).az + 0.05) < 1e-9)  // a refinement doesn't
    #expect(abs(d.bias(at: t1).az - 0.1) < 1e-9)
    #expect(abs(d.bias(at: t1.addingTimeInterval(10)).az - 0.13) < 1e-9)
}
