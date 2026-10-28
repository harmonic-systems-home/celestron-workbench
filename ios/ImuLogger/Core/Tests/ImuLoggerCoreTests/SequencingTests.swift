import Foundation
import Testing

@testable import ImuLoggerCore

@Test func bufferAssignsContiguousSequenceNumbersInOrder() {
    let buffer = AcquisitionBuffer(capacity: 100)
    for _ in 0..<10 { buffer.offer(stream: .gyro) { gyro($0) } }
    #expect(buffer.drain().map(\.seq) == Array(0..<10))
    for _ in 0..<5 { buffer.offer(stream: .gyro) { gyro($0) } }
    #expect(buffer.drain().map(\.seq) == Array(10..<15))
}

@Test func overflowCountsDropsWithoutCreatingSequenceGaps() {
    let buffer = AcquisitionBuffer(capacity: 4)
    for _ in 0..<6 { buffer.offer(stream: .gyro) { gyro($0) } }
    buffer.offer(stream: .accel) { gyro($0) }
    #expect(buffer.drain().map(\.seq) == [0, 1, 2, 3])
    #expect(buffer.counters.dropped == 3)
    #expect(buffer.counters.droppedByStream == [.gyro: 2, .accel: 1])
    #expect(buffer.counters.highWater == 4)
    buffer.offer(stream: .gyro) { gyro($0) }
    #expect(buffer.drain().map(\.seq) == [4])
}

@Test func concurrentProducersGetUniqueContiguousSequenceNumbers() async {
    let buffer = AcquisitionBuffer(capacity: 100_000)
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<8 {
            group.addTask {
                for _ in 0..<1000 { buffer.offer(stream: .gyro) { gyro($0) } }
            }
        }
    }
    let seqs = buffer.drain().map(\.seq)
    #expect(seqs == Array(0..<8000))
}

@Test func batchesAreContiguousAndBounded() {
    let samples = (0..<25).map { gyro(Seq($0)) }
    let batches = makeBatches(samples, sessionId: testSession, deviceId: testDevice, maxSamples: 10)
    #expect(batches.map(\.samples.count) == [10, 10, 5])
    #expect(batches.map(\.firstSeq) == [0, 10, 20])
    #expect(batches.map(\.lastSeq) == [9, 19, 24])
    #expect(batches.allSatisfy { $0.isContiguous })
    #expect(makeBatches([], sessionId: testSession, deviceId: testDevice, maxSamples: 10).isEmpty)
}

@Test func rateMeterReportsObservedIntervals() {
    var meter = RateMeter()
    for i in 0..<101 { meter.record(gyro(Seq(i), tNs: Nanos(i) * 10_000_000)) }
    let summary = meter.summary(for: .gyro)
    #expect(summary.count == 101)
    #expect(abs(summary.rateHz! - 100) < 1e-9)
    #expect(summary.minIntervalNs == 10_000_000)
    #expect(summary.maxIntervalNs == 10_000_000)
    #expect(meter.summary(for: .accel).rateHz == nil)
    meter.resetWindow()
    meter.record(gyro(101, tNs: 1_020_000_000))
    #expect(meter.summary(for: .gyro).maxIntervalNs == 20_000_000)
}

@Test func coreMotionUnitConversions() {
    let accel = Vec3.metersPerSecondSquared(fromG: 0, 0, -1)
    #expect(accel == Vec3(0, 0, -9.80665))
    #expect(PhoneClock.nanos(fromSeconds: 512.000_000_001) == 512_000_000_001)
    #expect(PhoneClock.nowNs() > 0)
    #expect(UUID(uuidString: PhoneClock.bootId) != nil)
    #expect(PhoneClock.bootId == PhoneClock.bootId.lowercased())
}
