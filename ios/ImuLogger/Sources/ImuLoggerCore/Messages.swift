import Foundation

// Wire messages, protocol version 1. Field names and shapes match
// schemas/protocol/v1.schema.json exactly; the shared examples in
// schemas/protocol/examples/ are decoded by the tests. Units and frames follow
// ADR 0002 and timestamps ADR 0001.

public let protocolVersion = 1

/// Standard gravity used to convert Core Motion's g to m/s² (ADR 0002).
public let standardGravity = 9.80665

/// Integer nanoseconds in the sender's monotonic clock domain (ADR 0001).
public typealias Nanos = Int64

/// Sequence number, one space per (session, device) across all streams.
public typealias Seq = UInt64

/// `[x, y, z]` in the phone body frame (ADR 0002). Encoded as a JSON array.
public struct Vec3: Equatable, Sendable, Codable {
    public var x: Double
    public var y: Double
    public var z: Double

    public init(_ x: Double, _ y: Double, _ z: Double) {
        self.x = x
        self.y = y
        self.z = z
    }

    public init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        x = try container.decode(Double.self)
        y = try container.decode(Double.self)
        z = try container.decode(Double.self)
        guard container.isAtEnd else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "Vec3 must have exactly 3 elements")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try container.encode(x)
        try container.encode(y)
        try container.encode(z)
    }
}

/// Hamilton unit quaternion with `w` as the scalar part (ADR 0002).
/// Always encoded with named components, never as an anonymous array.
public struct Quaternion: Equatable, Sendable, Codable {
    public var w: Double
    public var x: Double
    public var y: Double
    public var z: Double

    public init(w: Double, x: Double, y: Double, z: Double) {
        self.w = w
        self.x = x
        self.y = y
        self.z = z
    }
}

public enum Stream: String, Codable, Sendable, CaseIterable {
    case deviceMotion = "device_motion"
    case gyro
    case accel
    case magnetometer
}

public enum AttitudeReferenceFrame: String, Codable, Sendable, CaseIterable {
    case xArbitraryZVertical = "x_arbitrary_z_vertical"
    case xArbitraryCorrectedZVertical = "x_arbitrary_corrected_z_vertical"
    case xMagneticNorthZVertical = "x_magnetic_north_z_vertical"
    case xTrueNorthZVertical = "x_true_north_z_vertical"
}

public enum MagneticAccuracy: String, Codable, Sendable {
    case uncalibrated, low, medium, high
}

// MARK: - Messages

public enum Message: Equatable, Sendable, Codable {
    case hello(Hello)
    case helloAck(HelloAck)
    case sampleBatch(SampleBatch)
    case batchAck(BatchAck)
    case clockPing(ClockPing)
    case clockPong(ClockPong)
    case clockResult(ClockResult)
    case marker(Marker)
    case event(Event)
    case error(ErrorMessage)
    case bye(Bye)

    private enum TypeKey: String, CodingKey { case type }

    public init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeKey.self).decode(String.self, forKey: .type)
        switch type {
        case "hello": self = .hello(try Hello(from: decoder))
        case "hello_ack": self = .helloAck(try HelloAck(from: decoder))
        case "sample_batch": self = .sampleBatch(try SampleBatch(from: decoder))
        case "batch_ack": self = .batchAck(try BatchAck(from: decoder))
        case "clock_ping": self = .clockPing(try ClockPing(from: decoder))
        case "clock_pong": self = .clockPong(try ClockPong(from: decoder))
        case "clock_result": self = .clockResult(try ClockResult(from: decoder))
        case "marker": self = .marker(try Marker(from: decoder))
        case "event": self = .event(try Event(from: decoder))
        case "error": self = .error(try ErrorMessage(from: decoder))
        case "bye": self = .bye(try Bye(from: decoder))
        default:
            throw DecodingError.dataCorrupted(
                .init(codingPath: [TypeKey.type], debugDescription: "unknown message type \(type)"))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: TypeKey.self)
        try container.encode(typeName, forKey: .type)
        switch self {
        case .hello(let m): try m.encode(to: encoder)
        case .helloAck(let m): try m.encode(to: encoder)
        case .sampleBatch(let m): try m.encode(to: encoder)
        case .batchAck(let m): try m.encode(to: encoder)
        case .clockPing(let m): try m.encode(to: encoder)
        case .clockPong(let m): try m.encode(to: encoder)
        case .clockResult(let m): try m.encode(to: encoder)
        case .marker(let m): try m.encode(to: encoder)
        case .event(let m): try m.encode(to: encoder)
        case .error(let m): try m.encode(to: encoder)
        case .bye(let m): try m.encode(to: encoder)
        }
    }

    public var typeName: String {
        switch self {
        case .hello: "hello"
        case .helloAck: "hello_ack"
        case .sampleBatch: "sample_batch"
        case .batchAck: "batch_ack"
        case .clockPing: "clock_ping"
        case .clockPong: "clock_pong"
        case .clockResult: "clock_result"
        case .marker: "marker"
        case .event: "event"
        case .error: "error"
        case .bye: "bye"
        }
    }
}

public struct Hello: Equatable, Sendable, Codable {
    public var protocolVersion: Int
    public var sessionId: String
    public var device: DeviceInfo
    public var sensorAvailability: SensorAvailability
    public var streams: [Stream]
    public var attitudeReferenceFrame: AttitudeReferenceFrame
    public var requestedIntervalS: Double
    public var accelG0MS2: Double

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case sessionId = "session_id"
        case device
        case sensorAvailability = "sensor_availability"
        case streams
        case attitudeReferenceFrame = "attitude_reference_frame"
        case requestedIntervalS = "requested_interval_s"
        case accelG0MS2 = "accel_g0_m_s2"
    }
}

public struct DeviceInfo: Equatable, Sendable, Codable {
    /// Random UUID generated once by the app; not a hardware identifier.
    public var deviceId: String
    public var vendor: String
    public var model: String
    public var osVersion: String
    public var appVersion: String
    /// Changes whenever the phone's monotonic clock domain changes.
    public var bootId: String

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case vendor, model
        case osVersion = "os_version"
        case appVersion = "app_version"
        case bootId = "boot_id"
    }
}

public struct SensorAvailability: Equatable, Sendable, Codable {
    public var deviceMotion: Bool
    public var gyro: Bool
    public var accel: Bool
    public var magnetometer: Bool

    enum CodingKeys: String, CodingKey {
        case deviceMotion = "device_motion"
        case gyro, accel, magnetometer
    }
}

public struct HelloAck: Equatable, Sendable, Codable {
    public var protocolVersion: Int
    public var sessionId: String
    public var accepted: Bool
    /// nil when nothing is stored yet; encoded as an explicit `null`.
    public var highestContiguousSeq: Seq?
    public var reason: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case sessionId = "session_id"
        case accepted
        case highestContiguousSeq = "highest_contiguous_seq"
        case reason
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(protocolVersion, forKey: .protocolVersion)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(accepted, forKey: .accepted)
        try c.encode(highestContiguousSeq, forKey: .highestContiguousSeq)
        try c.encodeIfPresent(reason, forKey: .reason)
    }
}

public struct SampleBatch: Equatable, Sendable, Codable {
    public var protocolVersion: Int
    public var sessionId: String
    public var deviceId: String
    public var firstSeq: Seq
    public var lastSeq: Seq
    public var samples: [Sample]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case sessionId = "session_id"
        case deviceId = "device_id"
        case firstSeq = "first_seq"
        case lastSeq = "last_seq"
        case samples
    }

    /// True when samples are in seq order and cover `firstSeq...lastSeq` with no gaps.
    public var isContiguous: Bool {
        guard !samples.isEmpty, lastSeq >= firstSeq,
            samples.count == Int(lastSeq - firstSeq) + 1
        else { return false }
        return samples.enumerated().allSatisfy { $1.seq == firstSeq + Seq($0) }
    }
}

public enum Sample: Equatable, Sendable, Codable {
    case deviceMotion(DeviceMotionSample)
    case gyro(GyroSample)
    case accel(AccelSample)
    case magnetometer(MagnetometerSample)

    private enum StreamKey: String, CodingKey { case stream }

    public init(from decoder: Decoder) throws {
        let stream = try decoder.container(keyedBy: StreamKey.self)
            .decode(Stream.self, forKey: .stream)
        switch stream {
        case .deviceMotion: self = .deviceMotion(try DeviceMotionSample(from: decoder))
        case .gyro: self = .gyro(try GyroSample(from: decoder))
        case .accel: self = .accel(try AccelSample(from: decoder))
        case .magnetometer: self = .magnetometer(try MagnetometerSample(from: decoder))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: StreamKey.self)
        try container.encode(stream, forKey: .stream)
        switch self {
        case .deviceMotion(let s): try s.encode(to: encoder)
        case .gyro(let s): try s.encode(to: encoder)
        case .accel(let s): try s.encode(to: encoder)
        case .magnetometer(let s): try s.encode(to: encoder)
        }
    }

    public var stream: Stream {
        switch self {
        case .deviceMotion: .deviceMotion
        case .gyro: .gyro
        case .accel: .accel
        case .magnetometer: .magnetometer
        }
    }

    public var seq: Seq {
        switch self {
        case .deviceMotion(let s): s.seq
        case .gyro(let s): s.seq
        case .accel(let s): s.seq
        case .magnetometer(let s): s.seq
        }
    }

    public var tNs: Nanos {
        switch self {
        case .deviceMotion(let s): s.tNs
        case .gyro(let s): s.tNs
        case .accel(let s): s.tNs
        case .magnetometer(let s): s.tNs
        }
    }
}

/// Fused CMDeviceMotion. Accelerations in m/s², rates in rad/s.
public struct DeviceMotionSample: Equatable, Sendable, Codable {
    public var seq: Seq
    public var tNs: Nanos
    /// Rotates phone-body vectors into the session's reference frame.
    public var attitude: Quaternion
    public var rotationRate: Vec3
    public var gravity: Vec3
    public var userAccel: Vec3
    /// Always present on the wire; encoded as `null` when unavailable.
    public var magneticFieldUt: Vec3?
    public var magneticAccuracy: MagneticAccuracy?

    enum CodingKeys: String, CodingKey {
        case seq
        case tNs = "t_ns"
        case attitude
        case rotationRate = "rotation_rate"
        case gravity
        case userAccel = "user_accel"
        case magneticFieldUt = "magnetic_field_ut"
        case magneticAccuracy = "magnetic_accuracy"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(seq, forKey: .seq)
        try c.encode(tNs, forKey: .tNs)
        try c.encode(attitude, forKey: .attitude)
        try c.encode(rotationRate, forKey: .rotationRate)
        try c.encode(gravity, forKey: .gravity)
        try c.encode(userAccel, forKey: .userAccel)
        try c.encode(magneticFieldUt, forKey: .magneticFieldUt)
        try c.encode(magneticAccuracy, forKey: .magneticAccuracy)
    }
}

/// Raw CMGyroData, rad/s.
public struct GyroSample: Equatable, Sendable, Codable {
    public var seq: Seq
    public var tNs: Nanos
    public var rotationRate: Vec3

    enum CodingKeys: String, CodingKey {
        case seq
        case tNs = "t_ns"
        case rotationRate = "rotation_rate"
    }
}

/// Raw CMAccelerometerData, converted to m/s².
public struct AccelSample: Equatable, Sendable, Codable {
    public var seq: Seq
    public var tNs: Nanos
    public var accel: Vec3

    enum CodingKeys: String, CodingKey {
        case seq
        case tNs = "t_ns"
        case accel
    }
}

/// Raw CMMagnetometerData, µT.
public struct MagnetometerSample: Equatable, Sendable, Codable {
    public var seq: Seq
    public var tNs: Nanos
    public var magneticFieldUt: Vec3

    enum CodingKeys: String, CodingKey {
        case seq
        case tNs = "t_ns"
        case magneticFieldUt = "magnetic_field_ut"
    }
}

public struct BatchAck: Equatable, Sendable, Codable {
    public var protocolVersion: Int
    public var sessionId: String
    public var deviceId: String
    public var highestContiguousSeq: Seq

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case sessionId = "session_id"
        case deviceId = "device_id"
        case highestContiguousSeq = "highest_contiguous_seq"
    }
}

public struct ClockPing: Equatable, Sendable, Codable {
    public var protocolVersion: Int
    public var sessionId: String
    public var deviceId: String
    public var exchangeIndex: UInt64
    public var phoneSendNs: Nanos

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case sessionId = "session_id"
        case deviceId = "device_id"
        case exchangeIndex = "exchange_index"
        case phoneSendNs = "phone_send_ns"
    }
}

public struct ClockPong: Equatable, Sendable, Codable {
    public var protocolVersion: Int
    public var sessionId: String
    public var exchangeIndex: UInt64
    public var phoneSendNs: Nanos
    public var macReceiveNs: Nanos
    public var macSendNs: Nanos

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case sessionId = "session_id"
        case exchangeIndex = "exchange_index"
        case phoneSendNs = "phone_send_ns"
        case macReceiveNs = "mac_receive_ns"
        case macSendNs = "mac_send_ns"
    }
}

public struct ClockResult: Equatable, Sendable, Codable {
    public var protocolVersion: Int
    public var sessionId: String
    public var deviceId: String
    public var exchangeIndex: UInt64
    public var phoneSendNs: Nanos
    public var macReceiveNs: Nanos
    public var macSendNs: Nanos
    public var phoneReceiveNs: Nanos

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case sessionId = "session_id"
        case deviceId = "device_id"
        case exchangeIndex = "exchange_index"
        case phoneSendNs = "phone_send_ns"
        case macReceiveNs = "mac_receive_ns"
        case macSendNs = "mac_send_ns"
        case phoneReceiveNs = "phone_receive_ns"
    }
}

public struct Marker: Equatable, Sendable, Codable {
    public var protocolVersion: Int
    public var sessionId: String
    public var deviceId: String
    public var markerId: String
    public var label: String
    public var tNs: Nanos
    public var notes: String?

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case sessionId = "session_id"
        case deviceId = "device_id"
        case markerId = "marker_id"
        case label
        case tNs = "t_ns"
        case notes
    }
}

public struct Event: Equatable, Sendable, Codable {
    public enum Kind: String, Codable, Sendable {
        case thermalState = "thermal_state"
        case batteryState = "battery_state"
        case appState = "app_state"
        case interruption
        case droppedSamples = "dropped_samples"
        case bufferPressure = "buffer_pressure"
        case effectiveRate = "effective_rate"
        case attitudeDiscontinuity = "attitude_discontinuity"
    }

    public enum Severity: String, Codable, Sendable {
        case info, warning, error
    }

    public var protocolVersion: Int
    public var sessionId: String
    public var deviceId: String
    public var tNs: Nanos
    public var kind: Kind
    public var severity: Severity
    public var detail: [String: JSONValue]

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case sessionId = "session_id"
        case deviceId = "device_id"
        case tNs = "t_ns"
        case kind, severity, detail
    }
}

public struct ErrorMessage: Equatable, Sendable, Codable {
    public enum Code: String, Codable, Sendable {
        case unsupportedVersion = "unsupported_version"
        case unknownSession = "unknown_session"
        case deviceMismatch = "device_mismatch"
        case invalidMessage = "invalid_message"
        case `internal`
    }

    public var protocolVersion: Int
    public var code: Code
    public var message: String

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case code, message
    }
}

public struct Bye: Equatable, Sendable, Codable {
    public enum Reason: String, Codable, Sendable {
        case operatorStop = "operator_stop"
        case appTerminating = "app_terminating"
        case error
    }

    public var protocolVersion: Int
    public var sessionId: String
    public var deviceId: String
    /// nil when no samples were recorded; encoded as an explicit `null`.
    public var lastSeq: Seq?
    public var reason: Reason

    enum CodingKeys: String, CodingKey {
        case protocolVersion = "protocol_version"
        case sessionId = "session_id"
        case deviceId = "device_id"
        case lastSeq = "last_seq"
        case reason
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(protocolVersion, forKey: .protocolVersion)
        try c.encode(sessionId, forKey: .sessionId)
        try c.encode(deviceId, forKey: .deviceId)
        try c.encode(lastSeq, forKey: .lastSeq)
        try c.encode(reason, forKey: .reason)
    }
}
