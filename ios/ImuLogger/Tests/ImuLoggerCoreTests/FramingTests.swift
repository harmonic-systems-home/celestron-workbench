import Foundation
import Testing

@testable import ImuLoggerCore

private let bye = Message.bye(
    Bye(
        protocolVersion: protocolVersion,
        sessionId: "11111111-1111-4111-8111-111111111111",
        deviceId: "22222222-2222-4222-8222-222222222222",
        lastSeq: 7,
        reason: .operatorStop))

@Test func crcMatchesTheZlibCheckValue() {
    // CRC-32/ISO-HDLC check value; the Rust implementation tests the same.
    #expect(CRC32.checksum(Array("123456789".utf8)) == 0xCBF4_3926)
}

@Test func framesRoundTripAcrossArbitraryChunkBoundaries() throws {
    let stream = try Framing.encode(bye) + Framing.encode(bye)
    for chunkSize in 1...stream.count {
        var decoder = FrameDecoder()
        var out: [Message] = []
        var offset = 0
        while offset < stream.count {
            let end = min(offset + chunkSize, stream.count)
            decoder.push(stream.subdata(in: offset..<end))
            while let message = try decoder.nextMessage() { out.append(message) }
            offset = end
        }
        #expect(out == [bye, bye], "chunk size \(chunkSize)")
    }
}

@Test func rejectsCorruptedPayload() throws {
    var frame = try Framing.encode(bye)
    frame[7] ^= 0x01
    var decoder = FrameDecoder()
    decoder.push(frame)
    #expect(throws: Framing.Error.self) { try decoder.nextPayload() }
}

@Test func rejectsOversizedLength() {
    var decoder = FrameDecoder()
    let length = UInt32(Framing.maxPayloadLength + 1).bigEndian
    decoder.push(withUnsafeBytes(of: length) { Data($0) })
    #expect(throws: Framing.Error.tooLarge(Framing.maxPayloadLength + 1)) {
        try decoder.nextPayload()
    }
}
