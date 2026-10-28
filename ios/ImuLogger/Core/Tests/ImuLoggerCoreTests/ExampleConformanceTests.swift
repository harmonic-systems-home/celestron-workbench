import Foundation
import Testing

@testable import ImuLoggerCore

/// Reads the shared examples in schemas/protocol/examples/valid; the Rust tests read the same files.
private func validExamples() throws -> [(name: String, data: Data)] {
    let directory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // ImuLoggerCoreTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // Core
        .deletingLastPathComponent()  // ImuLogger
        .deletingLastPathComponent()  // ios
        .deletingLastPathComponent()  // repo root
        .appendingPathComponent("schemas/protocol/examples/valid")
    let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil
    )
    .filter { $0.pathExtension == "json" }
    .sorted { $0.lastPathComponent < $1.lastPathComponent }
    #expect(!files.isEmpty)
    return try files.map { ($0.lastPathComponent, try Data(contentsOf: $0)) }
}

@Test func validExamplesDecodeAndReencodeIdentically() throws {
    for (name, data) in try validExamples() {
        let message = try WireCoding.decode(data)
        let reencoded = try WireCoding.encode(message)
        // Compare as JSON objects so key order and 1 vs 1.0 don't matter,
        // but missing keys (such as an omitted null) do.
        let original = try JSONSerialization.jsonObject(with: data) as! NSDictionary
        let roundTripped = try JSONSerialization.jsonObject(with: reencoded) as! NSDictionary
        #expect(original == roundTripped, "\(name)")
        #expect(try WireCoding.decode(reencoded) == message, "\(name)")
    }
}

@Test func everyMessageTypeHasAnExample() throws {
    let types = Set(try validExamples().map { try WireCoding.decode($0.data).typeName })
    #expect(
        types == [
            "hello", "hello_ack", "sample_batch", "batch_ack", "clock_ping", "clock_pong",
            "clock_result", "marker", "event", "error", "bye",
        ])
}

@Test func sampleBatchExampleIsContiguous() throws {
    let data = try validExamples().first { $0.name == "sample_batch.json" }!.data
    guard case .sampleBatch(var batch) = try WireCoding.decode(data) else {
        Issue.record("not a sample batch")
        return
    }
    #expect(batch.isContiguous)
    batch.samples.remove(at: 1)
    #expect(!batch.isContiguous)
}

@Test func unavailableValuesAreEncodedAsExplicitNull() throws {
    let sample = Sample.deviceMotion(
        DeviceMotionSample(
            seq: 0, tNs: 1, attitude: Quaternion(w: 1, x: 0, y: 0, z: 0),
            rotationRate: Vec3(0, 0, 0), gravity: Vec3(0, 0, -standardGravity),
            userAccel: Vec3(0, 0, 0), magneticFieldUt: nil, magneticAccuracy: nil))
    let json = String(decoding: try JSONEncoder().encode(sample), as: UTF8.self)
    #expect(json.contains("\"magnetic_field_ut\":null"))
    #expect(json.contains("\"magnetic_accuracy\":null"))
}

@Test func vec3RejectsWrongLength() {
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Vec3.self, from: Data("[1, 2]".utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(Vec3.self, from: Data("[1, 2, 3, 4]".utf8))
    }
}
