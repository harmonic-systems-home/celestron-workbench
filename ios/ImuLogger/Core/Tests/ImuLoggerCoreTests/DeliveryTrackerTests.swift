import Testing

@testable import ImuLoggerCore

@Test func acknowledgementsReleaseBatches() {
    var tracker = DeliveryTracker(maxPendingBatches: 10)
    tracker.record(batch(0...4))
    tracker.record(batch(5...9))
    #expect(tracker.unacknowledgedSamples == 10)
    tracker.acknowledge(4)
    #expect(tracker.pendingCount == 1)
    #expect(tracker.unacknowledgedSamples == 5)
    tracker.acknowledge(2)  // stale ack is ignored
    #expect(tracker.acknowledged == 4)
    tracker.acknowledge(9)
    #expect(tracker.pendingCount == 0)
    #expect(tracker.unacknowledgedSamples == 0)
}

@Test func reconnectResendsOnlyWhatTheMacLacks() {
    var tracker = DeliveryTracker(maxPendingBatches: 10)
    tracker.record(batch(0...4))
    tracker.record(batch(5...9))
    tracker.record(batch(10...14))
    tracker.acknowledge(4)
    // The Mac stored the second batch but the ack was lost with the connection.
    #expect(tracker.reconnected(macHighest: 9) == .batches([batch(10...14)]))
}

@Test func firstConnectionResendsEverything() {
    var tracker = DeliveryTracker(maxPendingBatches: 10)
    tracker.record(batch(0...4))
    #expect(tracker.reconnected(macHighest: nil) == .batches([batch(0...4)]))
}

@Test func overflowFallsBackToTheLog() {
    var tracker = DeliveryTracker(maxPendingBatches: 2)
    for start in stride(from: Seq(0), to: 25, by: 5) { tracker.record(batch(start...(start + 4))) }
    #expect(tracker.needsLogReplay)
    #expect(tracker.reconnected(macHighest: nil) == .fromLog(after: nil))
    // Once acks catch up with what is still in memory, memory is enough again.
    tracker.acknowledge(14)
    #expect(!tracker.needsLogReplay)
    #expect(tracker.reconnected(macHighest: 14) == .batches([batch(15...19), batch(20...24)]))
}

@Test func receiverThatLostDataGetsAResendFromTheLog() {
    var tracker = DeliveryTracker(maxPendingBatches: 10)
    tracker.record(batch(0...4))
    tracker.record(batch(5...9))
    tracker.acknowledge(9)
    #expect(tracker.reconnected(macHighest: 4) == .fromLog(after: 4))
    #expect(tracker.acknowledged == 4)
    var fresh = DeliveryTracker(maxPendingBatches: 10)
    fresh.record(batch(0...4))
    fresh.acknowledge(4)
    #expect(fresh.reconnected(macHighest: nil) == .fromLog(after: nil))
}
