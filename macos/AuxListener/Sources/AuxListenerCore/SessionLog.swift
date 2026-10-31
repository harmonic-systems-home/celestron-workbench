import Foundation

/// Monotonic nanoseconds since boot (not counting sleep), the clock every
/// packet and mark is timed by.
public func monotonicNs() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

/// One NDJSON line per event (ADR 0018). Every line has `t_ns` (monotonic)
/// and `utc`; packets keep their raw bytes so they can always be decoded again.
public enum LogLine {
    public static func session(source: String, appVersion: String, at t: UInt64, utc: Date)
        -> String
    {
        line(
            [
                "event": "session", "source": source, "app_version": appVersion,
                "baud": Aux.baud, "format": 1,
            ], t, utc)
    }

    public static func packet(_ p: DecodedPacket, utc: Date) -> String {
        var fields: [String: Any] = [
            "event": "packet", "hex": hexBytes(p.packet.raw),
            "src": Int(p.packet.source), "dst": Int(p.packet.destination),
            "id": Int(p.packet.id), "data": hexBytes(p.packet.data),
            "reply": p.isReply, "polling": p.isPolling, "text": p.text,
        ]
        if let latency = p.latencyMs {
            fields["latency_ms"] = (latency * 1000).rounded() / 1000
        }
        return line(fields, p.at, utc)
    }

    public static func anomaly(_ a: Anomaly, utc: Date) -> String {
        line(
            [
                "event": "anomaly", "kind": a.kind.rawValue, "hex": hexBytes(a.bytes),
                "detail": a.detail,
            ], a.at, utc)
    }

    public static func mark(_ label: String, at t: UInt64, utc: Date) -> String {
        line(["event": "mark", "label": label], t, utc)
    }

    public static func connection(_ event: String, port: String, at t: UInt64, utc: Date)
        -> String
    {
        line(["event": event, "port": port], t, utc)
    }

    static func line(_ fields: [String: Any], _ t: UInt64, _ utc: Date) -> String {
        var all = fields
        all["t_ns"] = t
        all["utc"] = utcString(utc)
        let data = try! JSONSerialization.data(
            withJSONObject: all, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }

    public static func utcString(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }
}

/// Appends lines to one session file, created on first use.
public final class SessionLog {
    public let url: URL
    private let handle: FileHandle

    /// A new file named by the UTC start time, in `folder`.
    public init(folder: URL, start: Date) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let name =
            LogLine.utcString(start)
            .replacingOccurrences(of: ":", with: "-") + ".ndjson"
        url = folder.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
    }

    public func write(_ line: String) {
        handle.write(Data((line + "\n").utf8))
    }

    public func close() {
        try? handle.synchronize()
        try? handle.close()
    }

    deinit { close() }
}
