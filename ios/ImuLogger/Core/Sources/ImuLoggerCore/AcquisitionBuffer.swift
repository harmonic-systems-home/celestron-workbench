import Synchronization

/// Bounded hand-off from the Core Motion callback to the sender.
///
/// The callback calls `offer`, which assigns the next sequence number and
/// stores the sample, or counts a drop if the buffer is full (ADR 0006).
/// Sequence numbers are only assigned to accepted samples, so they stay
/// contiguous; drops are reported separately.
public final class AcquisitionBuffer: Sendable {
    public struct Counters: Equatable, Sendable {
        /// Next sequence number to assign; equals the number of samples accepted.
        public var nextSeq: Seq = 0
        public var dropped: UInt64 = 0
        public var droppedByStream: [SensorStream: UInt64] = [:]
        public var highWater: Int = 0
    }

    private struct State {
        var samples: [Sample] = []
        var counters = Counters()
    }

    public let capacity: Int
    private let state = Mutex(State())

    public init(capacity: Int) {
        precondition(capacity > 0)
        self.capacity = capacity
    }

    /// Accepts a sample if there is room. `make` receives the assigned sequence
    /// number and must be cheap: it runs under the lock.
    @discardableResult
    public func offer(stream: SensorStream, _ make: (Seq) -> Sample) -> Bool {
        state.withLock { state in
            guard state.samples.count < capacity else {
                state.counters.dropped += 1
                state.counters.droppedByStream[stream, default: 0] += 1
                return false
            }
            state.samples.append(make(state.counters.nextSeq))
            state.counters.nextSeq += 1
            state.counters.highWater = max(state.counters.highWater, state.samples.count)
            return true
        }
    }

    /// Removes and returns everything buffered, in sequence order.
    public func drain() -> [Sample] {
        state.withLock { state in
            let out = state.samples
            state.samples.removeAll(keepingCapacity: true)
            return out
        }
    }

    public var count: Int { state.withLock { $0.samples.count } }

    public var counters: Counters { state.withLock { $0.counters } }
}

/// Splits drained samples into protocol batches of at most `maxSamples`.
public func makeBatches(
    _ samples: [Sample], sessionId: String, deviceId: String, maxSamples: Int
) -> [SampleBatch] {
    precondition(maxSamples > 0)
    return stride(from: 0, to: samples.count, by: maxSamples).map { start in
        let chunk = Array(samples[start..<min(start + maxSamples, samples.count)])
        return SampleBatch(
            protocolVersion: protocolVersion, sessionId: sessionId, deviceId: deviceId,
            firstSeq: chunk.first!.seq, lastSeq: chunk.last!.seq, samples: chunk)
    }
}
