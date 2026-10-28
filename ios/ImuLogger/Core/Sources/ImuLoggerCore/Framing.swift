import Foundation

/// Frame format (ADR 0004): `u32 BE length | JSON payload | u32 BE CRC-32 of payload`.
public enum Framing {
    /// Largest payload accepted. Anything bigger closes the connection.
    public static let maxPayloadLength = 1 << 20

    public enum Error: Swift.Error, Equatable {
        case tooLarge(Int)
        case badCRC(expected: UInt32, actual: UInt32)
    }

    public static func encode(payload: Data) throws -> Data {
        guard payload.count <= maxPayloadLength else { throw Error.tooLarge(payload.count) }
        var frame = Data(capacity: payload.count + 8)
        frame.append(bigEndian: UInt32(payload.count))
        frame.append(payload)
        frame.append(bigEndian: CRC32.checksum(payload))
        return frame
    }

    public static func encode(_ message: Message) throws -> Data {
        try encode(payload: WireCoding.encode(message))
    }
}

/// Incremental decoder for a byte stream. Any thrown error means the stream is
/// unusable and the connection should be closed.
public struct FrameDecoder {
    private var buffer = Data()

    public init() {}

    public mutating func push(_ bytes: Data) {
        buffer.append(bytes)
    }

    /// Returns the next complete, CRC-checked payload, or nil if more bytes are needed.
    public mutating func nextPayload() throws -> Data? {
        guard buffer.count >= 4 else { return nil }
        let length = Int(buffer.readBigEndianUInt32(at: 0))
        guard length <= Framing.maxPayloadLength else { throw Framing.Error.tooLarge(length) }
        let total = 4 + length + 4
        guard buffer.count >= total else { return nil }
        let start = buffer.startIndex
        let payload = Data(buffer[(start + 4)..<(start + 4 + length)])
        let expected = buffer.readBigEndianUInt32(at: 4 + length)
        let actual = CRC32.checksum(payload)
        guard expected == actual else {
            throw Framing.Error.badCRC(expected: expected, actual: actual)
        }
        buffer.removeFirst(total)
        return payload
    }

    public mutating func nextMessage() throws -> Message? {
        guard let payload = try nextPayload() else { return nil }
        return try WireCoding.decode(payload)
    }
}

extension Data {
    fileprivate mutating func append(bigEndian value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }

    fileprivate func readBigEndianUInt32(at offset: Int) -> UInt32 {
        let start = startIndex + offset
        return self[start..<(start + 4)].reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
