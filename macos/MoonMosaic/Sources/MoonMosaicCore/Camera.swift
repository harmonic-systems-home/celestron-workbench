import Foundation

/// One frame from a camera: 8-bit raw pixels, row by row.
public struct Frame: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]
    /// When it was read (Mac wall clock).
    public let time: Date

    public init(width: Int, height: Int, pixels: [UInt8], time: Date) {
        self.width = width
        self.height = height
        self.pixels = pixels
        self.time = time
    }
}

public struct CameraInfo: Sendable, Equatable {
    public let name: String
    public let width: Int
    public let height: Int
    public let pixelSizeUm: Double
    public let isColor: Bool
    /// 0 RG, 1 BG, 2 GR, 3 GB (ZWO's ASI_BAYER_PATTERN).
    public let bayerPattern: Int
}

/// What the app needs from a camera: video frames at a set exposure and gain.
public protocol Camera: AnyObject, Sendable {
    var info: CameraInfo { get }
    func configure(exposureUs: Int, gain: Int) throws
    func start() throws
    /// The next frame, or nil if none arrives within `timeoutMs`.
    func frame(timeoutMs: Int) throws -> Frame?
    func stop()
}

public struct CameraError: Error, CustomStringConvertible {
    public let description: String
}

/// ZWO's ASICamera2 library, loaded at run time (ADR 0019). The structure
/// and function layouts follow ZWO's ASICamera2.h. 8-bit raw video at full
/// resolution.
public final class ZWOLibrary: @unchecked Sendable {
    /// Where to look, in order: an Apple silicon build installed for this app
    /// (ASIStudio's copy is Intel-only), then ASIStudio's.
    public static let candidatePaths = [
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(
                "Library/Application Support/MoonMosaic/lib/libASICamera2.dylib"
            )
            .path,
        "/Applications/ASIStudio.app/Contents/Frameworks/libASICamera2.dylib",
    ]

    /// Whether any candidate loads on this Mac (for tests and the app's checks).
    public static var isAvailable: Bool { (try? ZWOLibrary()) != nil }

    typealias Count = @convention(c) () -> Int32
    typealias Property = @convention(c) (UnsafeMutableRawPointer, Int32) -> Int32
    typealias ById = @convention(c) (Int32) -> Int32
    typealias SetROI = @convention(c) (Int32, Int32, Int32, Int32, Int32) -> Int32
    typealias SetControl = @convention(c) (Int32, Int32, Int, Int32) -> Int32
    typealias VideoData = @convention(c) (Int32, UnsafeMutablePointer<UInt8>, Int, Int32) -> Int32
    typealias Version = @convention(c) () -> UnsafePointer<CChar>?

    let handle: UnsafeMutableRawPointer
    let count: Count
    let property: Property
    let open: ById
    let initialize: ById
    let close: ById
    let setROI: SetROI
    let setControl: SetControl
    let startVideo: ById
    let stopVideo: ById
    let videoData: VideoData
    let version: Version

    /// Layout of ASI_CAMERA_INFO (248 bytes on 64-bit macOS).
    static let infoSize = 248
    static let offsetID = 64
    static let offsetHeight = 72
    static let offsetWidth = 80
    static let offsetIsColor = 88
    static let offsetBayer = 92
    static let offsetPixelSize = 192

    public init(paths: [String] = ZWOLibrary.candidatePaths) throws {
        var failures: [String] = []
        var loaded: UnsafeMutableRawPointer?
        for path in paths {
            if let h = dlopen(path, RTLD_NOW | RTLD_LOCAL) {
                loaded = h
                break
            }
            failures.append("\(path): \(dlerror().map { String(cString: $0) } ?? "not loadable")")
        }
        guard let h = loaded else {
            throw CameraError(
                description: "no loadable ZWO camera library:\n" + failures.joined(separator: "\n"))
        }
        func sym<T>(_ name: String, _: T.Type) throws -> T {
            guard let p = dlsym(h, name) else {
                throw CameraError(description: "\(name) is missing from ZWO's library")
            }
            return unsafeBitCast(p, to: T.self)
        }
        handle = h
        count = try sym("ASIGetNumOfConnectedCameras", Count.self)
        property = try sym("ASIGetCameraProperty", Property.self)
        open = try sym("ASIOpenCamera", ById.self)
        initialize = try sym("ASIInitCamera", ById.self)
        close = try sym("ASICloseCamera", ById.self)
        setROI = try sym("ASISetROIFormat", SetROI.self)
        setControl = try sym("ASISetControlValue", SetControl.self)
        startVideo = try sym("ASIStartVideoCapture", ById.self)
        stopVideo = try sym("ASIStopVideoCapture", ById.self)
        videoData = try sym("ASIGetVideoData", VideoData.self)
        version = try sym("ASIGetSDKVersion", Version.self)
    }

    public var sdkVersion: String {
        version().map { String(cString: $0) } ?? "?"
    }

    /// Connected cameras, with the ID each opens by.
    public func cameras() -> [(id: Int32, info: CameraInfo)] {
        (0..<count()).compactMap { index in
            let buffer = UnsafeMutableRawPointer.allocate(byteCount: Self.infoSize, alignment: 8)
            defer { buffer.deallocate() }
            buffer.initializeMemory(as: UInt8.self, repeating: 0, count: Self.infoSize)
            guard property(buffer, index) == 0 else { return nil }
            let name = String(
                decoding: UnsafeRawBufferPointer(start: buffer, count: 64).prefix { $0 != 0 },
                as: UTF8.self)
            let info = CameraInfo(
                name: name,
                width: buffer.load(fromByteOffset: Self.offsetWidth, as: Int.self),
                height: buffer.load(fromByteOffset: Self.offsetHeight, as: Int.self),
                pixelSizeUm: buffer.load(fromByteOffset: Self.offsetPixelSize, as: Double.self),
                isColor: buffer.load(fromByteOffset: Self.offsetIsColor, as: Int32.self) != 0,
                bayerPattern: Int(buffer.load(fromByteOffset: Self.offsetBayer, as: Int32.self))
            )
            return (buffer.load(fromByteOffset: Self.offsetID, as: Int32.self), info)
        }
    }

    deinit { dlclose(handle) }
}

/// A ZWO camera opened for 8-bit raw video.
public final class ZWOCamera: Camera, @unchecked Sendable {
    public let info: CameraInfo
    private let library: ZWOLibrary
    private let id: Int32
    private var buffer: [UInt8]

    /// Opens the first connected camera whose name contains `named`.
    public init(library: ZWOLibrary, named: String = "") throws {
        guard
            let (id, info) = library.cameras().first(where: {
                named.isEmpty || $0.info.name.contains(named)
            })
        else {
            throw CameraError(
                description: "no ZWO camera\(named.isEmpty ? "" : " named \(named)") connected")
        }
        try Self.check(library.open(id), "open the camera (is ASIStudio using it?)")
        try Self.check(library.initialize(id), "initialize the camera")
        try Self.check(
            library.setROI(id, Int32(info.width), Int32(info.height), 1, 0), "set full-frame RAW8")
        self.library = library
        self.id = id
        self.info = info
        buffer = [UInt8](repeating: 0, count: info.width * info.height)
    }

    public func configure(exposureUs: Int, gain: Int) throws {
        try Self.check(library.setControl(id, 1, exposureUs, 0), "set the exposure")
        try Self.check(library.setControl(id, 0, gain, 0), "set the gain")
    }

    public func start() throws {
        try Self.check(library.startVideo(id), "start video")
    }

    public func frame(timeoutMs: Int) throws -> Frame? {
        let code = buffer.withUnsafeMutableBufferPointer {
            library.videoData(id, $0.baseAddress!, $0.count, Int32(timeoutMs))
        }
        // 11 is ASI_ERROR_TIMEOUT: no frame yet.
        if code == 11 { return nil }
        try Self.check(code, "read a frame")
        return Frame(width: info.width, height: info.height, pixels: buffer, time: Date())
    }

    public func stop() {
        _ = library.stopVideo(id)
    }

    deinit {
        _ = library.stopVideo(id)
        _ = library.close(id)
    }

    static func check(_ code: Int32, _ what: String) throws {
        guard code == 0 else {
            throw CameraError(description: "couldn't \(what): ZWO error \(code)")
        }
    }
}
