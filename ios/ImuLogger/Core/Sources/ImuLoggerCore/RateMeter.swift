/// Observed sample intervals per stream, from source timestamps. Reports what
/// the phone actually delivered; the app never assumes a maximum rate.
public struct RateMeter: Sendable {
    public struct Summary: Equatable, Sendable {
        public var count: Int
        public var rateHz: Double?
        public var meanIntervalNs: Double?
        public var minIntervalNs: Nanos?
        public var maxIntervalNs: Nanos?
    }

    private struct StreamState {
        var lastNs: Nanos?
        var count = 0
        var intervalCount = 0
        var intervalSum: Double = 0
        var minInterval: Nanos?
        var maxInterval: Nanos?
        var firstNs: Nanos?
    }

    private var streams: [SensorStream: StreamState] = [:]

    public init() {}

    public mutating func record(_ sample: Sample) {
        var s = streams[sample.stream] ?? StreamState()
        let t = sample.tNs
        if let last = s.lastNs {
            let interval = t - last
            s.intervalCount += 1
            s.intervalSum += Double(interval)
            s.minInterval = min(s.minInterval ?? interval, interval)
            s.maxInterval = max(s.maxInterval ?? interval, interval)
        } else {
            s.firstNs = t
        }
        s.lastNs = t
        s.count += 1
        streams[sample.stream] = s
    }

    public func summary(for stream: SensorStream) -> Summary {
        guard let s = streams[stream] else { return Summary(count: 0) }
        let mean = s.intervalCount > 0 ? s.intervalSum / Double(s.intervalCount) : nil
        return Summary(
            count: s.count,
            rateHz: mean.flatMap { $0 > 0 ? 1e9 / $0 : nil },
            meanIntervalNs: mean,
            minIntervalNs: s.minInterval,
            maxIntervalNs: s.maxInterval)
    }

    public var activeStreams: [SensorStream] {
        SensorStream.allCases.filter { streams[$0] != nil }
    }

    /// Starts a new measurement window, keeping the last timestamp so the
    /// first interval of the new window is still measured.
    public mutating func resetWindow() {
        for (stream, s) in streams {
            streams[stream] = StreamState(lastNs: s.lastNs)
        }
    }
}

extension RateMeter.Summary {
    public init(count: Int) {
        self.init(
            count: count, rateHz: nil, meanIntervalNs: nil, minIntervalNs: nil, maxIntervalNs: nil)
    }
}
