import Foundation

@testable import ImuLoggerCore

let testSession = "11111111-1111-4111-8111-111111111111"
let testDevice = "22222222-2222-4222-8222-222222222222"

func gyro(_ seq: Seq, tNs: Nanos? = nil) -> Sample {
    .gyro(GyroSample(seq: seq, tNs: tNs ?? Nanos(seq) * 10_000_000, rotationRate: Vec3(0, 0, 0)))
}

func motion(
    _ seq: Seq, tNs: Nanos, attitude: Quaternion, rate: Vec3 = Vec3(0, 0, 0)
) -> DeviceMotionSample {
    DeviceMotionSample(
        seq: seq, tNs: tNs, attitude: attitude, rotationRate: rate,
        gravity: Vec3(0, 0, -standardGravity), userAccel: Vec3(0, 0, 0),
        magneticFieldUt: nil, magneticAccuracy: nil)
}

func batch(_ seqs: ClosedRange<Seq>) -> SampleBatch {
    SampleBatch(
        protocolVersion: protocolVersion, sessionId: testSession, deviceId: testDevice,
        firstSeq: seqs.lowerBound, lastSeq: seqs.upperBound, samples: seqs.map { gyro($0) })
}

func testHello() -> Hello {
    Hello(
        protocolVersion: protocolVersion, sessionId: testSession,
        device: DeviceInfo(
            deviceId: testDevice, vendor: "Apple", model: "test", osVersion: "0",
            appVersion: "0", bootId: "33333333-3333-4333-8333-333333333333"),
        sensorAvailability: SensorAvailability(
            deviceMotion: true, gyro: true, accel: true, magnetometer: false),
        streams: [.gyro], attitudeReferenceFrame: .xArbitraryZVertical,
        requestedIntervalS: 0.01, accelG0MS2: standardGravity)
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ImuLoggerCoreTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Polls until `condition` holds or the timeout passes.
func eventually(
    timeout: TimeInterval = 10, _ condition: @Sendable () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
