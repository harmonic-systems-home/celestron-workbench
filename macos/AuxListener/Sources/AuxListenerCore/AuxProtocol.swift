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
        case 0x10: "Azimuth"
        case 0x11: "Altitude"
        case 0x12: "Focuser"
        case 0x20: "App"
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
}

/// Motor controller message IDs (docs/references.md).
public enum MotorMessage {
    public static func name(_ id: UInt8) -> String? {
        switch id {
        case 0x01: "GET_POSITION"
        case 0x02: "GOTO_FAST"
        case 0x04: "SET_POSITION"
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

/// A 24-bit big-endian position in degrees.
func degrees(_ bytes: ArraySlice<UInt8>) -> Double? {
    guard bytes.count == 3 else { return nil }
    let units = bytes.reduce(0) { $0 << 8 | Int($1) }
    return Double(units) / Aux.unitsPerRev * 360.0
}
