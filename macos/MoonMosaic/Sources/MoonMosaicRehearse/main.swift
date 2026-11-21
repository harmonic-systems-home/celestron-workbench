import Foundation
import MoonMosaicCore

// The test runner (ADR 0022 amendment 7): the flow on the simulated mount and
// camera for many seeded scenarios, one after another, with a JSON record.
//
//   swift run -c release MoonMosaicRehearse [first-seed] [count] [--tiles N] [--speed K] [--out file.json] [--keep dir] [--verbose]
//       [--camera 662|482|both]
//   swift run -c release MoonMosaicRehearse --set phases [--rotations 30,210] [--camera 662|482|both] [--phase "waxing crescent"] ...
//
// The phases set: each major phase (waxing crescent to waning crescent, full
// included) × direct and mirrored (diagonal) × each rotation × each camera.
setvbuf(stdout, nil, _IOLBF, 0)
let args = Array(CommandLine.arguments.dropFirst())
let numbers = args.prefix { !$0.hasPrefix("--") }.compactMap { UInt64($0) }
let first = numbers.first ?? 1
let count = numbers.count > 1 ? Int(numbers[1]) : 5
func option(_ name: String) -> String? {
    args.firstIndex(of: name).flatMap { args.indices.contains($0 + 1) ? args[$0 + 1] : nil }
}
let tiles = option("--tiles").flatMap(Int.init) ?? 2
let speed = option("--speed").flatMap(Double.init) ?? 5
let verbose = args.contains("--verbose")
let out = option("--out").map { URL(fileURLWithPath: $0) }
// Keep each scenario's frames and notes (survey, orient) under this folder.
let keep = option("--keep").map { URL(fileURLWithPath: $0) }

struct Report: Codable {
    let started: Date
    let build: String
    let results: [Rehearsal.Result]
    let passed: Int
    let failed: Int
}

let cameras: [Rehearsal.CameraModel] =
    switch option("--camera") {
    case "482": [.asi482mc]
    case "both": [.asi662mc, .asi482mc]
    default: [.asi662mc]
    }
var scenarios: [Rehearsal.Scenario] = []
if option("--set") == "phases" {
    let rotations = (option("--rotations") ?? "30,210").split(separator: ",").compactMap { Double($0) }
    var seed = first
    for camera in cameras {
        let only = option("--phase").flatMap { name in Rehearsal.Phase.allCases.first { $0.rawValue == name } }
        for phase in Rehearsal.Phase.allCases where only == nil || phase == only {
            for diagonal in [false, true] {
                for rotation in rotations {
                    var s = Rehearsal.Scenario(seed: seed, phase: phase, camera: camera, rotationDeg: rotation, diagonal: diagonal)
                    s.daytime = args.contains("--day")
                    scenarios.append(s)
                    seed += 1
                }
            }
        }
    }
} else if let scene = option("--scene") {
    // One photo as the scene, at its own moment and place, for `count` seeds.
    for seed in first..<(first + UInt64(count)) {
        var s = Rehearsal.Scenario(seed: seed)
        s.scenePath = scene
        s.camera = cameras[0]
        s.exposureUs = option("--exposure-ms").flatMap(Double.init).map { Int($0 * 1000) }
        s.gain = option("--gain").flatMap(Int.init)
        if let r = option("--rotation").flatMap(Double.init) { s.cameraRotationDeg = r }
        if let d = option("--diagonal") { s.diagonal = d == "yes" }
        if let m = option("--moon"), case let v = m.split(separator: ",").compactMap({ Double($0) }), v.count == 2 {
            (s.moonOffsetAz, s.moonOffsetAlt) = (v[0], v[1])
        }
        scenarios.append(s)
    }
} else {
    for seed in first..<(first + UInt64(count)) {
        for camera in cameras {
            var s = Rehearsal.Scenario(seed: seed)
            s.camera = camera
            scenarios.append(s)
        }
    }
}
print("\(scenarios.count) scenarios.")

let started = Date()
var results: [Rehearsal.Result] = []
for s in scenarios {
    let seed = s.seed
    print(
        String(
            format: "seed %llu: %@%@, camera %.0f°%@, Moon %.2f°, %.2f° off, seeing %.1f″", seed,
            s.camera == .asi482mc ? "ASI482MC" : "ASI662MC", s.phase.map { ", " + $0.rawValue } ?? "",
            s.cameraRotationDeg, s.diagonal ? " (diagonal)" : "", s.moonOffsetAz, s.moonOffsetAlt, s.seeingArcsec))
    let dir = keep?.appendingPathComponent("seed-\(seed)-\(s.camera.rawValue)")
    if let dir { try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
    let r = await Rehearsal.run(s, speed: speed, tiles: tiles, folder: dir, log: { if verbose { print("    \($0)") } })
    for step in r.steps {
        print(String(format: "  %@ %-14@ %6.1f s  %@", step.ok ? "ok  " : "FAIL", step.name, step.seconds, step.note ?? ""))
    }
    results.append(r)
}
let passed = results.filter(\.ok).count
print("\(passed) of \(results.count) scenarios passed.")
if let out {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    let build = (try? FileManager.default.attributesOfItem(atPath: CommandLine.arguments[0]))?[.modificationDate] as? Date
    let report = Report(
        started: started, build: build.map { ISO8601DateFormatter().string(from: $0) } ?? "?", results: results,
        passed: passed, failed: results.count - passed)
    try e.encode(report).write(to: out)
    print("Wrote \(out.path).")
}
exit(passed == results.count ? 0 : 1)
