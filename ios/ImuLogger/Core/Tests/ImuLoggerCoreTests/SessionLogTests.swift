import Foundation
import Testing

@testable import ImuLoggerCore

@Test func logRoundTripsMessagesAsNDJSON() throws {
    let url = try temporaryDirectory().appendingPathComponent("session.ndjson")
    let log = try SessionLog(creating: url)
    let messages: [Message] = [
        .hello(testHello()), .sampleBatch(batch(0...4)), .sampleBatch(batch(5...9)),
    ]
    try messages.forEach(log.append)
    try log.close()
    #expect(try SessionLog.read(url) == messages)
    let text = try String(contentsOf: url, encoding: .utf8)
    #expect(text.split(separator: "\n").count == 3)
    #expect(text.hasSuffix("\n"))
}

@Test func logRefusesToOverwrite() throws {
    let url = try temporaryDirectory().appendingPathComponent("session.ndjson")
    try SessionLog(creating: url).close()
    #expect(throws: (any Error).self) { try SessionLog(creating: url) }
}

@Test func logSkipsATruncatedFinalLine() throws {
    let url = try temporaryDirectory().appendingPathComponent("session.ndjson")
    let log = try SessionLog(creating: url)
    try log.append(.sampleBatch(batch(0...4)))
    try log.close()
    let handle = try FileHandle(forWritingTo: url)
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(#"{"type":"sample_ba"#.utf8))
    try handle.close()
    #expect(try SessionLog.read(url) == [.sampleBatch(batch(0...4))])
}

@Test func logSelectsBatchesAfterASequenceNumber() throws {
    let url = try temporaryDirectory().appendingPathComponent("session.ndjson")
    let log = try SessionLog(creating: url)
    for range in [0...4, 5...9, 10...14] as [ClosedRange<Seq>] {
        try log.append(.sampleBatch(batch(range)))
    }
    try log.close()
    #expect(try SessionLog.batches(in: url, after: nil).map(\.firstSeq) == [0, 5, 10])
    #expect(try SessionLog.batches(in: url, after: 7).map(\.firstSeq) == [5, 10])
    #expect(try SessionLog.batches(in: url, after: 14).isEmpty)
}
