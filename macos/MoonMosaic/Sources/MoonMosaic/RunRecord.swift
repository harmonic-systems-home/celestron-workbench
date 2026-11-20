import Foundation

/// One session's record, from Connect to Disconnect (2026-11-20): every
/// step with its time and its designed estimate, the time spent idle, the
/// nudges and undos, and the capture's numbers. Written as JSON to the
/// setup folder (and copied into each run folder), updated after every
/// step, so changes in timing can be tracked from session to session. No
/// coordinates: the site is the app's private setting.
struct RunRecord: Codable {
    struct Step: Codable {
        var name: String
        var started: Date
        var seconds: Double
        var estimateSeconds: Double?
        var ok: Bool
    }
    struct Capture: Codable {
        var tiles: Int
        var done: Int
        var failed: Int
        var seconds: Double
        var secondsPerTile: Double?
        var folder: String
    }

    var app = "Moon Mosaic"
    /// When this build of the app was made (its executable's date).
    var build: Date?
    var started: Date
    var updated: Date
    var simulated: Bool
    var mount: String
    var camera: String
    var scene: String?
    var steps: [Step] = []
    /// Time in steps, and time between them (waiting on the operator).
    var busySeconds = 0.0
    var idleSeconds = 0.0
    var totalSeconds = 0.0
    var nudges = 0
    var undos = 0
    var captures: [Capture] = []
    /// Per step name: how many times, total and mean seconds.
    var totals: [String: Total] = [:]
    struct Total: Codable {
        var count: Int
        var seconds: Double
        var meanSeconds: Double
    }

    mutating func add(_ step: Step) {
        steps.append(step)
        busySeconds += step.seconds
        var t = totals[step.name] ?? Total(count: 0, seconds: 0, meanSeconds: 0)
        t.count += 1
        t.seconds += step.seconds
        t.meanSeconds = t.seconds / Double(t.count)
        totals[step.name] = t
    }

    mutating func touch(_ now: Date = Date()) {
        updated = now
        totalSeconds = now.timeIntervalSince(started)
        idleSeconds = max(0, totalSeconds - busySeconds)
    }

    func write(to folders: [URL]) {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        guard let data = try? e.encode(self) else { return }
        for f in folders {
            try? data.write(to: f.appendingPathComponent("run-record.json"))
        }
    }

    static var buildDate: Date? {
        (try? FileManager.default.attributesOfItem(atPath: CommandLine.arguments[0]))?[.modificationDate] as? Date
    }
}
