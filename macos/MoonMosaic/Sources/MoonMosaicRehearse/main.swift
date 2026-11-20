import Foundation
import MoonMosaicCore

// The test runner (ADR 0022 amendment 7): the flow on the simulated mount and
// camera for many seeded scenarios, one after another, with a JSON record.
//
//   swift run -c release MoonMosaicRehearse [first-seed] [count] [--tiles N] [--speed K] [--out file.json] [--verbose]
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

struct Report: Codable {
    let started: Date
    let build: String
    let results: [Rehearsal.Result]
    let passed: Int
    let failed: Int
}

let started = Date()
var results: [Rehearsal.Result] = []
for seed in first..<(first + UInt64(count)) {
    let s = Rehearsal.Scenario(seed: seed)
    print(
        String(
            format: "seed %llu: camera %.0f°%@, Moon %.2f°, %.2f° off, seeing %.1f″", seed, s.cameraRotationDeg,
            s.diagonal ? " (diagonal)" : "", s.moonOffsetAz, s.moonOffsetAlt, s.seeingArcsec))
    let r = await Rehearsal.run(s, speed: speed, tiles: tiles, log: { if verbose { print("    \($0)") } })
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
