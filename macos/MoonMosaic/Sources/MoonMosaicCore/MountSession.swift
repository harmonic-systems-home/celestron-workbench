import CCwbMount
import Foundation

/// A mount session through the Rust adapter (ADR 0019): the hand controller
/// is opened, checked and driven by the tested Celestron adapter, with the
/// interlock controller in encoder-only mode. Calls are thread-safe; the
/// session runs on a thread of its own and stops the mount when closed.
public final class MountSession: @unchecked Sendable {
    public enum Axis: String, Codable, Sendable {
        case azimuth, altitude
    }

    public enum Direction: String, Codable, Sendable {
        case positive, negative
    }

    public struct Opened: Decodable, Sendable {
        public let controllerVersion: String?
        public let model: String?
        public let motorVersions: [String?]
        /// azm+, azm−, alt+, alt−.
        public let antiBacklash: [Int?]
        public let positionsDeg: [Double]
        public let simulated: Bool
    }

    public struct Status: Decodable, Sendable {
        public let state: String
        /// Each axis's last idle read, in its own angle.
        public let positionsDeg: [Double]?
        public let positionsAgeMs: Int?
        /// The tube's true altitude, once a reference is set.
        public let altitudeDeg: Double?
        public let linkLost: Bool
        public let lastRecord: Record?
        public let lastFault: Fault?
        /// Alerts and notes since the last status call.
        public let messages: [String]
    }

    public struct Record: Decodable, Sendable {
        /// (stage, time) pairs; the last is where the command ended up.
        public let stages: [Stage]
        public let reason: String?
        public let fault: String?

        public var lastStage: String? { stages.last?.name }
    }

    public struct Stage: Decodable, Sendable {
        public let name: String
        public let tNs: Int64

        public init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            name = try c.decode(String.self)
            tNs = try c.decode(Int64.self)
        }
    }

    public struct Fault: Decodable, Sendable {
        public let kind: String
        public let detail: String
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public let id: UInt64
    public let opened: Opened

    /// `port`: a serial device, or "simulate". `safety` overrides the
    /// controller's safety settings (encoder-only is always on). `trace`:
    /// a file for every byte to and from the hand controller and every
    /// request, state change and message, for working out faults later.
    public init(port: String, safety: [String: Any] = [:], trace: URL? = nil) throws {
        var options: [String: Any] = ["port": port, "safety": safety]
        if let trace { options["trace"] = trace.path }
        let reply = try Self.call { cwb_session_open(Self.json(options)) }
        guard let id = (reply["session"] as? NSNumber)?.uint64Value,
            let opened = reply["opened"]
        else { throw Failure(description: "unexpected reply: \(reply)") }
        self.id = id
        self.opened = try Self.decode(Opened.self, from: opened)
    }

    deinit {
        _ = try? Self.call { cwb_session_close(id) }
    }

    public func status() throws -> Status {
        let reply = try Self.call { cwb_session_status(id) }
        return try Self.decode(Status.self, from: reply)
    }

    public func arm() throws { try command(["op": "arm"]) }
    public func disarm() throws { try command(["op": "disarm"]) }
    public func reset() throws { try command(["op": "reset"]) }
    public func stop() throws { try command(["op": "stop"]) }
    public func emergencyStop() throws { try command(["op": "emergency_stop"]) }

    /// Ties the altitude encoder to the sky: the tube's true altitude now.
    public func setAltitudeReference(_ altitudeDeg: Double) throws {
        try command(["op": "reference", "altitude_deg": altitudeDeg])
    }

    /// A goto relative to the axis's last read position; returns the request ID.
    @discardableResult
    public func goto(
        _ axis: Axis, by deltaDeg: Double, fast: Bool = false, approach: Direction? = nil
    ) throws -> String {
        var request: [String: Any] = [
            "op": "goto", "axis": axis.rawValue, "delta_deg": deltaDeg, "fast": fast,
        ]
        if let approach { request["approach"] = approach.rawValue }
        let reply = try command(request)
        return reply["request_id"] as? String ?? ""
    }

    @discardableResult
    private func command(_ request: [String: Any]) throws -> [String: Any] {
        let text = Self.json(request)
        return try Self.call { cwb_session_command(id, text) }
    }

    // MARK: - The C boundary

    private static func json(_ object: [String: Any]) -> String {
        let data = try! JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    /// Calls into Rust, takes ownership of the returned string, and turns
    /// `{"ok": false}` into an error.
    private static func call(_ body: () -> UnsafeMutablePointer<CChar>?) throws -> [String: Any] {
        guard let pointer = body() else { throw Failure(description: "no reply") }
        defer { cwb_string_free(pointer) }
        let data = Data(String(cString: pointer).utf8)
        guard let reply = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure(description: "reply isn't an object")
        }
        if reply["ok"] as? Bool != true {
            throw Failure(description: reply["error"] as? String ?? "failed: \(reply)")
        }
        return reply
    }

    private static func decode<T: Decodable>(_ type: T.Type, from value: Any) throws -> T {
        let data = try JSONSerialization.data(withJSONObject: value)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(type, from: data)
    }
}
