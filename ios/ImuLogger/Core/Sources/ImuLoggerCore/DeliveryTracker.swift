/// Tracks which sample batches the Mac has durably stored, and what to resend
/// after a reconnect (ADR 0004). Pure state; the uplink drives it.
public struct DeliveryTracker: Sendable {
    public enum Resend: Equatable, Sendable {
        /// Resend these batches, in order.
        case batches([SampleBatch])
        /// Too much was unacknowledged to keep in memory; reread batches after
        /// `seq` (all if nil) from the session log.
        case fromLog(after: Seq?)
    }

    /// Highest sequence number the Mac has acknowledged, if any.
    public private(set) var acknowledged: Seq?
    /// Highest sequence number handed to the tracker.
    public private(set) var recorded: Seq?
    private var pending: [SampleBatch] = []
    private var overflowed = false
    public let maxPendingBatches: Int

    public init(maxPendingBatches: Int) {
        precondition(maxPendingBatches > 0)
        self.maxPendingBatches = maxPendingBatches
    }

    public var pendingCount: Int { pending.count }

    /// True when the session log must be reread to resend (memory window exceeded).
    public var needsLogReplay: Bool { overflowed }

    /// Samples recorded but not yet acknowledged.
    public var unacknowledgedSamples: UInt64 {
        guard let recorded else { return 0 }
        guard let acknowledged else { return recorded + 1 }
        return recorded > acknowledged ? recorded - acknowledged : 0
    }

    /// Records a batch that has been written to the log and is about to be sent.
    public mutating func record(_ batch: SampleBatch) {
        recorded = max(recorded ?? batch.lastSeq, batch.lastSeq)
        if let acknowledged, batch.lastSeq <= acknowledged { return }
        pending.append(batch)
        if pending.count > maxPendingBatches {
            pending.removeFirst(pending.count - maxPendingBatches)
            overflowed = true
        }
    }

    /// Applies an acknowledgement. Acks never move backwards.
    public mutating func acknowledge(_ seq: Seq) {
        if let acknowledged, seq <= acknowledged { return }
        acknowledged = seq
        pending.removeAll { $0.lastSeq <= seq }
        if overflowed, let first = pending.first, first.firstSeq <= seq + 1 {
            overflowed = false
        }
        if overflowed, pending.isEmpty, let recorded, seq >= recorded {
            overflowed = false
        }
    }

    /// After `hello_ack`: what the Mac already has, and what must be resent.
    /// A Mac that lost data can report a lower number than before; resend from there.
    public mutating func reconnected(macHighest: Seq?) -> Resend {
        if let macHighest {
            if let acknowledged, macHighest < acknowledged {
                self.acknowledged = macHighest
                overflowed = true  // Older batches were already dropped from memory.
            } else {
                acknowledge(macHighest)
            }
        } else if acknowledged != nil {
            acknowledged = nil
            overflowed = true
        }
        if overflowed { return .fromLog(after: acknowledged) }
        return .batches(pending)
    }
}
