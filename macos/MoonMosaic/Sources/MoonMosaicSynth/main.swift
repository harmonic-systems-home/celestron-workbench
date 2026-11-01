import Foundation
import MoonMosaicCore

// A synthetic Moon mosaic session (ADR 0019, step 6), for testing
// scripts/moon-process.sh without a mount: SER tiles of the fake camera's
// Moon with aiming errors, drift, jitter and noise, the session log as the
// app writes it, and truth.pgm, the whole Moon in the camera's orientation
// and scale, centred on the Moon.
//
//   MoonMosaicSynth <folder> [--width 640] [--height 360] [--scale 1.0]
//                   [--rotation 25] [--frames 15] [--diameter 0.53] [--seed 1]

var options = [
    "width": 640.0, "height": 360.0, "scale": 1.0, "rotation": 25.0, "frames": 15.0,
    "diameter": 0.53, "seed": 1.0,
]
var args = Array(CommandLine.arguments.dropFirst())
guard let folderPath = args.first, !folderPath.hasPrefix("--") else {
    FileHandle.standardError.write(Data("usage: MoonMosaicSynth <folder> [--width N] …\n".utf8))
    exit(2)
}
args.removeFirst()
while args.count >= 2, args[0].hasPrefix("--"), let v = Double(args[1]) {
    let key = String(args[0].dropFirst(2))
    guard options[key] != nil else { break }
    options[key] = v
    args.removeFirst(2)
}
guard args.isEmpty else {
    FileHandle.standardError.write(Data("unknown arguments: \(args)\n".utf8))
    exit(2)
}

let width = Int(options["width"]!)
let height = Int(options["height"]!)
let scale = options["scale"]!
let folder = URL(fileURLWithPath: folderPath)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

/// A small, repeatable random source.
struct Random {
    var state: UInt64

    mutating func next() -> Double {
        state ^= state << 13
        state ^= state >> 7
        state ^= state << 17
        return Double(state >> 11) / Double(1 << 53)
    }

    mutating func gaussian() -> Double {
        (-2 * log(max(next(), 1e-12))).squareRoot() * cos(2 * .pi * next())
    }
}
var rng = Random(state: UInt64(options["seed"]!) &* 0x9E37_79B9_7F4A_7C15 | 1)

let camera = FakeCamera(
    width: width, height: height, scale: scale, rotationDeg: options["rotation"]!)

// Calibrate as the session does: two moves, the image shifts they cause.
func shot(_ x: Double, _ y: Double) throws -> Frame {
    camera.pointing = (x, y)
    return try camera.frame(timeoutMs: 0)!
}
let move = 0.2 * Double(min(width, height)) * scale
let (f0, f1, f2) = (try shot(0, 0), try shot(move, 0), try shot(move, move))
let r1 = Registration.shift(from: f0, to: f1)
let r2 = Registration.shift(from: f1, to: f2)
guard
    let calibration = CameraCalibration(
        (SkyOffset(x: move, y: 0), PixelOffset(x: r1.dx, y: r1.dy)),
        (SkyOffset(x: 0, y: move), PixelOffset(x: r2.dx, y: r2.dy)))
else { fatalError("calibration failed") }

let plan = MosaicPlanner.plan(
    moonDiameterDeg: options["diameter"]!, calibration: calibration, frameWidth: width,
    frameHeight: height)
let sessionLog = SessionLog(folder: folder)
let start = Date(timeIntervalSince1970: 1_800_000_000)
try? FileManager.default.removeItem(at: sessionLog.url)
try sessionLog.plan(
    plan, calibration: calibration, moonDiameterDeg: options["diameter"]!, colorID: 0,
    time: start)

// Each tile: aimed a little off (up to 8% of the frame), drifting through
// the video, with a pixel or so of jitter per frame and sensor noise. The
// log's measured centre is the true one plus a few pixels of encoder error.
let frames = Int(options["frames"]!)
var t = start
for tile in plan.tiles {
    let aim = PixelOffset(
        x: tile.center.x + 0.08 * Double(width) * (2 * rng.next() - 1),
        y: tile.center.y + 0.08 * Double(height) * (2 * rng.next() - 1))
    let driftAngle = 2 * Double.pi * rng.next()
    let name = String(format: "tile-%02d-r%02d-c%02d.ser", tile.id, tile.row, tile.column)
    let writer = try SerWriter(
        url: folder.appendingPathComponent(name), width: width, height: height, colorID: 0,
        instrument: "Synthetic", telescope: "Moon mosaic", start: t)
    let first = t
    for i in 0..<frames {
        let along = (Double(i) - Double(frames - 1) / 2) * 0.5
        let c = PixelOffset(
            x: aim.x + along * cos(driftAngle) + rng.gaussian(),
            y: aim.y + along * sin(driftAngle) + rng.gaussian())
        let sky = calibration.sky(for: PixelOffset(x: -c.x, y: -c.y))
        camera.pointing = (sky.x, sky.y)
        let f = try camera.frame(timeoutMs: 0)!
        let noisy = f.pixels.map { UInt8(max(0, min(255, Double($0) + 6 * rng.gaussian()))) }
        try writer.append(Frame(width: width, height: height, pixels: noisy, time: t))
        t.addTimeInterval(0.05)
    }
    try writer.finish()
    try sessionLog.done(
        tile.id, file: name, frames: frames, sharpness: 0, start: first,
        end: t.addingTimeInterval(-0.05), positionDeg: nil,
        measured: PixelOffset(x: aim.x + 2 * rng.gaussian(), y: aim.y + 2 * rng.gaussian()))
    t.addTimeInterval(4)
}

// The truth: the whole Moon, centred, in the camera's orientation and scale.
let side = Int((2.2 * plan.moonRadiusPixels).rounded()) & ~1
let whole = FakeCamera(width: side, height: side, scale: scale, rotationDeg: options["rotation"]!)
whole.pointing = (0, 0)
let truth = try whole.frame(timeoutMs: 0)!
var pgm = Data("P5\n\(side) \(side)\n255\n".utf8)
pgm.append(contentsOf: truth.pixels)
try pgm.write(to: folder.appendingPathComponent("truth.pgm"))
print(
    String(
        format: "%d tiles, %d frames each, %.3f″/px, camera turned %.1f°, truth %d px square.",
        plan.tiles.count, frames, calibration.arcsecPerPixel, calibration.rotationDeg, side))
