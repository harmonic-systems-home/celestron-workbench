import Foundation

/// One camera shared by the session and the live view (ADR 0019): frames are
/// read by one caller at a time, the latest is kept for the live view, and the
/// camera runs while anyone has started it.
public final class SharedCamera: Camera, @unchecked Sendable {
    public let camera: Camera
    private let reading = NSLock()
    private let lock = NSLock()
    private var users = 0
    private var _latest: Frame?

    public init(_ camera: Camera) {
        self.camera = camera
    }

    public var info: CameraInfo { camera.info }

    /// The last frame anyone read.
    public var latest: Frame? { lock.withLock { _latest } }

    public func configure(exposureUs: Int, gain: Int) throws {
        try reading.withLock { try camera.configure(exposureUs: exposureUs, gain: gain) }
    }

    public func start() throws {
        try lock.withLock {
            if users == 0 { try camera.start() }
            users += 1
        }
    }

    public func frame(timeoutMs: Int) throws -> Frame? {
        let f = try reading.withLock { try camera.frame(timeoutMs: timeoutMs) }
        if let f { lock.withLock { _latest = f } }
        return f
    }

    public func stop() {
        lock.withLock {
            users = max(users - 1, 0)
            if users == 0 { camera.stop() }
        }
    }
}
