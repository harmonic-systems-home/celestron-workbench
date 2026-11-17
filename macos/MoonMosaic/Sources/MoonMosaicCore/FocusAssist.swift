import Foundation

/// Focus assist (ADR 0022). Focusing the Moon by hand is a one-dimensional
/// search on the knob, but two things get in the way: the sharpest point is
/// hard to judge by eye, and touching the knob shakes the image so any reading
/// taken then is worthless. This gives:
///
/// - a per-frame **sharpness** score (gradient energy — the Moon's limb and
///   texture sharpen steeply near focus),
/// - a short **history** so the operator can run a manual binary search on the
///   knob and watch the trend, and
/// - a **settled** flag: the frame-to-frame motion of the bright blob is large
///   while a hand is on the knob and small once only atmospheric seeing is
///   left, so the score is trusted only after the touch-shake decays.
///
/// Feed it frames as they arrive; read `history`, `latest` and `settledBest`.
public final class FocusAssist: @unchecked Sendable {
    public struct Sample: Sendable, Equatable {
        public let time: Date
        /// Mean gradient energy per pixel; higher is sharper.
        public let sharpness: Double
        /// How far the blob moved from the previous frame, in pixels; nil when
        /// there was no previous blob to compare with.
        public let jitterPx: Double?
        /// The recent blob jitter has fallen below the shake threshold: the
        /// operator's touch-shake is gone and only seeing remains, so
        /// `sharpness` is worth acting on.
        public let settled: Bool
    }

    private let settleThresholdPx: Double
    private let settleWindow: Int
    private let historyCount: Int
    private var lastCentroid: (x: Double, y: Double)?
    private var recentJitter: [Double] = []
    public private(set) var history: [Sample] = []

    /// `settleThresholdPx`: blob jitter below this (RMS over `settleWindow`
    /// frames) counts as settled — set it a little above the seeing's own
    /// jitter. `historyCount`: samples kept for the trend.
    public init(settleThresholdPx: Double = 1.5, settleWindow: Int = 4, historyCount: Int = 600) {
        self.settleThresholdPx = settleThresholdPx
        self.settleWindow = max(1, settleWindow)
        self.historyCount = max(1, historyCount)
    }

    /// Scores `frame`, updates the shake state and history, and returns the
    /// new sample. Sharpness is the existing Bayer-aware `Focus.sharpness`
    /// (ADR 0019) over the frame's middle, where the tracked Moon sits.
    @discardableResult
    public func add(_ frame: Frame) -> Sample {
        let sharp = Focus.sharpness(Focus.crop(frame))
        let blob = Blob.find(frame)

        var jitter: Double?
        if let blob, let last = lastCentroid {
            jitter = hypot(blob.x - last.x, blob.y - last.y)
        }
        lastCentroid = blob.map { ($0.x, $0.y) }

        if let jitter {
            recentJitter.append(jitter)
            if recentJitter.count > settleWindow { recentJitter.removeFirst() }
        } else {
            // No blob to track: treat as unsettled and forget the window.
            recentJitter.removeAll()
        }
        let settled =
            recentJitter.count >= settleWindow
            && (recentJitter.map { $0 * $0 }.reduce(0, +) / Double(recentJitter.count)).squareRoot()
                < settleThresholdPx

        let sample = Sample(time: frame.time, sharpness: sharp, jitterPx: jitter, settled: settled)
        history.append(sample)
        if history.count > historyCount { history.removeFirst() }
        return sample
    }

    public var latest: Sample? { history.last }

    /// The sharpest settled sample so far — the knob position to return to.
    public var settledBest: Sample? {
        history.filter(\.settled).max { $0.sharpness < $1.sharpness }
    }

    /// Forget the shake and history (e.g. when refocusing for a new optic).
    public func reset() {
        lastCentroid = nil
        recentJitter.removeAll()
        history.removeAll()
    }
}
