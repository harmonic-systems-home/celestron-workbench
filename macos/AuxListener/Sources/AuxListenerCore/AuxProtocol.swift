/// The Celestron AUX bus packet format and the names this app knows
/// (ADR 0018). Community-documented (docs/references.md): a packet is
/// `0x3B`, length, source, destination, message ID, data, checksum, where
/// length counts source, destination, ID and data, and the checksum is the
/// two's complement of the sum of the bytes from length to the last data byte.
public enum Aux {
    public static let preamble: UInt8 = 0x3B
    /// At 19,200 baud, 8N1.
    public static let baud = 19_200
    /// Longest length byte accepted; longer is treated as a broken frame.
    public static let maxLength = 40
    /// Motor positions: 24 bits per revolution.
    public static let unitsPerRev = 16_777_216.0

    public static func checksum<C: Collection>(_ body: C) -> UInt8 where C.Element == UInt8 {
        let sum = body.reduce(UInt32(0)) { $0 &+ UInt32($1) }
        return UInt8(truncatingIfNeeded: (~sum &+ 1))
    }

    /// A whole packet's bytes.
    public static func encode(
        source: UInt8, destination: UInt8, id: UInt8, data: [UInt8] = []
    ) -> [UInt8] {
        let body = [UInt8(3 + data.count), source, destination, id] + data
        return [preamble] + body + [checksum(body)]
    }
}

/// One framed packet with a valid checksum.
public struct AuxPacket: Equatable, Sendable {
    public let source: UInt8
    public let destination: UInt8
    public let id: UInt8
    public let data: [UInt8]
    /// Every byte, preamble and checksum included.
    public let raw: [UInt8]

    public init?(raw: [UInt8]) {
        guard raw.count >= 6, raw[0] == Aux.preamble, Int(raw[1]) == raw.count - 3,
            Aux.checksum(raw[1..<(raw.count - 1)]) == raw[raw.count - 1]
        else { return nil }
        self.raw = raw
        source = raw[2]
        destination = raw[3]
        id = raw[4]
        data = Array(raw[5..<(raw.count - 1)])
    }
}

/// Names for AUX device addresses (community-documented).
public enum AuxDevice {
    public static func name(_ address: UInt8) -> String {
        switch address {
        case 0x00: "Any"
        case 0x01: "Main board"
        case 0x04: "Hand control"
        case 0x0d: "Hand control+"
        case 0x0e: "StarSense HC"
        case 0x10: "Azimuth"
        case 0x11: "Altitude"
        case 0x12: "Focuser"
        case 0x17: "Dew heater"
        case 0x20: "App (Wi-Fi)"
        case 0xb0: "GPS"
        case 0xb4: "StarSense"
        case 0xb5: "Wi-Fi"
        case 0xb6: "Battery"
        case 0xb7: "Charger"
        case 0xbf: "Lights"
        default: hex(address)
        }
    }

    public static func isMotor(_ address: UInt8) -> Bool {
        address == 0x10 || address == 0x11
    }

    /// Hand controllers and apps: they ask, and devices answer them.
    public static func isController(_ address: UInt8) -> Bool {
        [0x04, 0x0d, 0x0e, 0x20].contains(address)
    }
}

/// Motor controller message IDs (docs/references.md).
public enum MotorMessage {
    public static func name(_ id: UInt8) -> String? {
        switch id {
        case 0x01: "GET_POSITION"
        case 0x02: "GOTO_FAST"
        case 0x04: "SET_POSITION"
        case 0x05: "GET_MODEL"
        case 0x06: "SET_POS_GUIDERATE"
        case 0x07: "SET_NEG_GUIDERATE"
        case 0x10: "SET_POS_BACKLASH"
        case 0x11: "SET_NEG_BACKLASH"
        case 0x13: "SLEW_DONE"
        case 0x17: "GOTO_SLOW"
        case 0x18: "AT_INDEX"
        case 0x19: "SEEK_INDEX"
        case 0x24: "MOVE_POS"
        case 0x25: "MOVE_NEG"
        case 0x40: "GET_POS_BACKLASH"
        case 0x41: "GET_NEG_BACKLASH"
        case 0xfc: "GET_APPROACH"
        case 0xfd: "SET_APPROACH"
        case 0xfe: "GET_VERSION"
        default: nil
        }
    }

    /// Routine reads that controllers repeat several times a second; the
    /// feed hides them by default so commands stand out.
    public static func isPolling(_ id: UInt8) -> Bool {
        id == 0x01 || id == 0x13
    }
}

/// The mount's battery (0xB6). Message 0x10 returns six bytes: the last four
/// its voltage in microvolts, big-endian. The first is a state (0 on
/// battery, 2 on external power, which may not mean charging: 1 not seen),
/// the second a coarse level that steps
/// from 2 to 1 at about 9.75 V.
public enum BatteryMessage {
    public static let address: UInt8 = 0xb6
    public static let getVoltage: UInt8 = 0x10

    public struct Reading: Equatable, Sendable {
        public let volts: Double
        public let level: UInt8
        public let state: UInt8
    }

    public static func reading(_ data: [UInt8]) -> Reading? {
        guard data.count == 6 else { return nil }
        let microvolts = data[2...].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        return Reading(volts: Double(microvolts) / 1e6, level: data[1], state: data[0])
    }
}

/// StarSense camera message IDs, from community captures rather than
/// Celestron (docs/references.md): the meanings are best guesses, and IDs
/// not listed, such as 0x05, are unknown.
public enum StarSenseMessage {
    public static let address: UInt8 = 0xb4

    public static func name(_ id: UInt8) -> String? {
        switch id {
        case 0x3e: "SET_ALIGN_CENTER"
        case 0x3f: "GET_ALIGN_CENTER"
        case 0x90: "RESET_CAPTURE"
        case 0x91: "GET_STATUS"
        case 0x92: "GET_CAPTURE_DATA"
        case 0x94: "START_CAPTURE"
        case 0x9f: "GET_IMAGE"
        case 0xfe: "GET_VERSION"
        default: nil
        }
    }

    /// Messages the camera answers only once a capture is done.
    public static func isCapture(_ id: UInt8) -> Bool {
        id == 0x90 || id == 0x94
    }
}

/// The stars the StarSense camera found in a capture, sent in a `3C` bulk
/// frame after its answer to GET_CAPTURE_DATA (ADR 0018). The data is
/// little-endian 32-bit float pairs, x then y in pixels, brightest first;
/// the answer's second byte is how many. From 10 captures on 2026-11-10:
/// positions fell within 1280 × 960, the brightest star in the calibration
/// capture sat 1.6 px from the centre the hand controller then set, and the
/// list stopped at 100 with the last pair 0, 0.
public struct StarList: Equatable, Sendable {
    public struct Star: Equatable, Sendable {
        public let x: Float
        public let y: Float
    }

    /// Every pair sent, empty ones included.
    public let stars: [Star]

    /// From a whole unstuffed frame (`3C`, length, data, checksum); nil if
    /// the data isn't whole pairs.
    public init?(frame: [UInt8]) {
        guard frame.count > Bulk.headerCount else { return nil }
        let data = frame[Bulk.headerCount..<(frame.count - 1)]
        guard !data.isEmpty, data.count % 8 == 0 else { return nil }
        var stars: [Star] = []
        var i = data.startIndex
        while i < data.endIndex {
            guard let x = littleEndian32(data[i..<(i + 4)]),
                let y = littleEndian32(data[(i + 4)..<(i + 8)])
            else { return nil }
            stars.append(Star(x: Float(bitPattern: x), y: Float(bitPattern: y)))
            i += 8
        }
        self.stars = stars
    }

    /// The pairs that aren't 0, 0.
    public var found: [Star] { stars.filter { $0.x != 0 || $0.y != 0 } }

    public var text: String {
        let found = found
        var line = "Star list: \(found.count) star\(found.count == 1 ? "" : "s")"
        if let first = found.first {
            line += String(format: ", brightest at x %.1f, y %.1f", first.x, first.y)
        }
        if found.count < stars.count {
            line += " (\(stars.count) sent, \(stars.count - found.count) empty)"
        }
        return line
    }
}

public func hex(_ byte: UInt8) -> String {
    let digits = String(byte, radix: 16, uppercase: true)
    return "0x" + (digits.count == 1 ? "0" + digits : digits)
}

public func hexBytes<C: Collection>(_ bytes: C) -> String where C.Element == UInt8 {
    bytes.map { b in
        let digits = String(b, radix: 16, uppercase: true)
        return digits.count == 1 ? "0" + digits : digits
    }.joined(separator: " ")
}

/// A 32-bit little-endian number.
func littleEndian32(_ bytes: ArraySlice<UInt8>) -> UInt32? {
    guard bytes.count == 4 else { return nil }
    return bytes.reversed().reduce(0) { $0 << 8 | UInt32($1) }
}

/// A 24-bit big-endian position in degrees.
func degrees(_ bytes: ArraySlice<UInt8>) -> Double? {
    guard bytes.count == 3 else { return nil }
    let units = bytes.reduce(0) { $0 << 8 | Int($1) }
    return Double(units) / Aux.unitsPerRev * 360.0
}
