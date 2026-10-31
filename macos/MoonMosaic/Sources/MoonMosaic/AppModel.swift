import AppKit
import CoreGraphics
import Foundation
import MoonMosaicCore

/// Everything the window shows and does (ADR 0019). Long operations run off
/// the main thread; their results come back here.
@MainActor
final class AppModel: ObservableObject {
    // Settings, kept between launches.
    @Published var latitude: Double { didSet { save() } }
    @Published var longitude: Double { didSet { save() } }
    @Published var focalLengthMm: Double { didSet { save() } }
    @Published var overlap: Double { didSet { save() } }
    @Published var videoSeconds: Double { didSet { save() } }
    @Published var exposureMs: Double { didSet { save() } }
    @Published var gain: Int { didSet { save() } }
    @Published var simulate: Bool { didSet { save() } }
    @Published var dayPalette: Bool { didSet { save() } }
    @Published var folder: URL { didSet { save() } }

    // State.
    @Published private(set) var connected = false
    @Published private(set) var mountState = "Not connected"
    @Published private(set) var altitude: Double?
    @Published private(set) var busy: String?
    @Published private(set) var log: [String] = []
    @Published private(set) var plan: MosaicPlan?
    @Published private(set) var tileStates: [Int: TileState] = [:]
    @Published private(set) var preview: MosaicPreview?
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var liveImage: CGImage?
    @Published private(set) var hereSet = false
    @Published private(set) var calibrated = false
    /// Capture progress: tiles finished of those asked for, and when the
    /// rest should be done (re-estimated as each tile finishes).
    @Published private(set) var captureDone = 0
    @Published private(set) var captureTotal = 0
    @Published private(set) var finishAt: Date?
    private var captureStarted = Date()
    /// Re-aiming at the Moon's centre every few seconds, to hold it in view
    /// (for focusing) when the mount isn't tracking.
    @Published private(set) var holding = false
    private var holdTask: Task<Void, Never>?
    @Published var selected: Set<Int> = []
    @Published var showSettings = false

    private var mount: MountSession?
    private var camera: SharedCamera?
    private var session: MosaicSession?
    private var runFolder: URL?
    private let paused = Flag()
    private var liveTask: Task<Void, Never>?
    private var pollTimer: Timer?

    /// One settings file however the app is started (as Moon Mosaic.app or
    /// from the build folder, which macOS would give separate preferences).
    private static let support = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("MoonMosaic")
    private static let settingsFile = support.appendingPathComponent("settings.json")

    init() {
        // The file, or the preferences this app kept before it.
        let d =
            (try? Data(contentsOf: Self.settingsFile)).flatMap {
                try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
            } ?? UserDefaults.standard.dictionaryRepresentation()
        latitude = d["latitude"] as? Double ?? 0
        longitude = d["longitude"] as? Double ?? 0
        focalLengthMm = d["focalLengthMm"] as? Double ?? 2000
        overlap = d["overlap"] as? Double ?? 0.25
        videoSeconds = d["videoSeconds"] as? Double ?? 3
        exposureMs = d["exposureMs"] as? Double ?? 2
        gain = d["gain"] as? Int ?? 100
        simulate = d["simulate"] as? Bool ?? false
        dayPalette = d["dayPalette"] as? Bool ?? false
        folder =
            (d["folder"] as? String).map { URL(fileURLWithPath: $0) }
            ?? Self.support.appendingPathComponent("sessions")
        save()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func save() {
        let d: [String: Any] = [
            "latitude": latitude, "longitude": longitude, "focalLengthMm": focalLengthMm,
            "overlap": overlap, "videoSeconds": videoSeconds, "exposureMs": exposureMs,
            "gain": gain, "simulate": simulate, "dayPalette": dayPalette, "folder": folder.path,
        ]
        do {
            try FileManager.default.createDirectory(
                at: Self.support, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: d, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: Self.settingsFile, options: .atomic)
        } catch {
            say("Couldn't save settings: \(error.localizedDescription)")
        }
    }

    var siteSet: Bool { latitude != 0 || longitude != 0 }

    func say(_ text: String) {
        let stamp = Self.clock.string(from: Date())
        log.append("\(stamp)  \(text)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
        if let runFolder {
            let line = Data("\(stamp)  \(text)\n".utf8)
            let url = runFolder.appendingPathComponent("log.txt")
            if let h = try? FileHandle(forWritingTo: url) {
                h.seekToEndOfFile()
                h.write(line)
                try? h.close()
            } else {
                try? line.write(to: url)
            }
        }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    // MARK: - Connecting

    func connect() {
        guard !connected else { return }
        guard siteSet else {
            say("Set your site's latitude and longitude in Settings first.")
            showSettings = true
            return
        }
        let simulate = self.simulate
        busy = "Connecting"
        Task.detached {
            do {
                let port: String
                if simulate {
                    port = "simulate"
                } else {
                    guard let p = serialPorts(vendorID: prolificVendorID).first else {
                        throw MosaicError(
                            description:
                                "No hand controller on USB. Plug it in (re-plug after a mount power cycle)."
                        )
                    }
                    port = p
                }
                let mount = try MountSession(port: port, safety: ["max_goto_deg": 1.0])
                let camera = SharedCamera(
                    simulate
                        ? FakeCamera(width: 1920, height: 1080, scale: 0.3, rotationDeg: 25)
                        : try ZWOCamera(library: ZWOLibrary()))
                await MainActor.run { self.connected(mount: mount, camera: camera, port: port) }
            } catch {
                await MainActor.run {
                    self.busy = nil
                    self.say("Couldn't connect: \(error)")
                }
            }
        }
    }

    private func connected(mount: MountSession, camera: SharedCamera, port: String) {
        self.mount = mount
        self.camera = camera
        let site = Site(latitudeDeg: latitude, longitudeDeg: longitude)
        var settings = MosaicSettings(site: site)
        settings.focalLengthMm = focalLengthMm
        settings.overlap = overlap
        settings.videoSeconds = videoSeconds
        settings.exposureUs = Int(exposureMs * 1000)
        settings.gain = gain
        // Rehearsing: the clock runs from the next time the Moon is high here.
        let realTime: @Sendable () -> Date = { Date() }
        let clock = simulate ? Self.rehearsalClock(site: site) : realTime
        let session = MosaicSession(
            mount: mount, camera: camera, settings: settings, clock: clock,
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            })
        if let fake = camera.camera as? FakeCamera {
            fake.provider = { [weak session] in
                guard let session, let here = session.here,
                    let p = try? session.mount.status().positionsDeg
                else { return (0, 0) }
                let s = session.relativeMove(
                    from: (here.time, [here.azimuthDeg, here.altitudeDeg]), to: (clock(), p))
                return (s.x, s.y)
            }
        }
        self.session = session
        connected = true
        busy = nil
        let o = mount.opened
        say(
            "Connected\(o.simulated ? " (SIMULATED)" : "") to \(o.model ?? "?") on \(port); camera \(camera.info.name), \(camera.info.width)×\(camera.info.height)."
        )
        startLive()
    }

    static func rehearsalClock(site: Site) -> @Sendable () -> Date {
        var t = Date()
        for _ in 0..<(24 * 30) {
            let moon = Ephemeris.moon(at: t, from: site).horizontal
            let sep = Ephemeris.separationDeg(
                Ephemeris.sun(at: t), Ephemeris.moon(at: t).equatorial)
            if moon.altDeg > 30, sep > 60 { break }
            t.addTimeInterval(3600)
        }
        let started = Date()
        let epoch = t
        return { epoch.addingTimeInterval(Date().timeIntervalSince(started)) }
    }

    func disconnect() {
        stopHold()
        stopLive()
        try? mount?.stop()
        session = nil
        camera = nil
        mount = nil
        connected = false
        hereSet = false
        calibrated = false
        mountState = "Not connected"
        say("Disconnected.")
    }

    // MARK: - Live view

    private func startLive() {
        guard liveTask == nil, let camera else { return }
        let exposure = Int(exposureMs * 1000)
        let gain = self.gain
        liveTask = Task.detached { [weak self] in
            do {
                try camera.configure(exposureUs: exposure, gain: gain)
                try camera.start()
            } catch {
                await MainActor.run { self?.say("Live view: \(error)") }
                return
            }
            while !Task.isCancelled {
                // The session's frames while it is reading (a goto's
                // check, a tile's video); otherwise one of our own.
                let recent = camera.latest.map { Date().timeIntervalSince($0.time) < 0.5 }
                if let frame = recent == true ? camera.latest : try? camera.frame(timeoutMs: 500) {
                    let image = Imaging.image(fromFrame: frame)
                    await MainActor.run { self?.liveImage = image }
                }
                try? await Task.sleep(for: .milliseconds(300))
            }
            camera.stop()
        }
    }

    private func stopLive() {
        liveTask?.cancel()
        liveTask = nil
    }

    // MARK: - Steps

    /// Runs an operation off the main thread; the live view carries on.
    private func perform(
        _ name: String, _ body: @escaping @Sendable (MosaicSession) async throws -> Void
    ) {
        guard let session, busy == nil else { return }
        busy = name
        // A step takes over the mount: Hold ends, after its move in progress.
        let hold = holdTask
        stopHold()
        Task.detached { [weak self] in
            await hold?.value
            do {
                try await body(session)
            } catch {
                await MainActor.run { self?.say("\(name) failed: \(error)") }
            }
            await MainActor.run {
                guard let self else { return }
                self.busy = nil
                self.finishAt = nil
                self.sync()
            }
        }
    }

    func toggleHold() {
        if holding {
            stopHold()
            return
        }
        guard let session, hereSet, busy == nil else { return }
        holding = true
        say("Holding on the Moon's centre.")
        holdTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                do {
                    try await session.goToSky(SkyOffset(x: 0, y: 0))
                } catch {
                    await MainActor.run {
                        self?.say("Hold stopped: \(error)")
                        self?.stopHold()
                    }
                    return
                }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private func stopHold() {
        holding = false
        holdTask?.cancel()
        holdTask = nil
    }

    func here() {
        perform("Here") { try await $0.markHere() }
    }

    func calibrate() {
        perform("Calibrating") { try await $0.calibrate() }
    }

    func makePlan() {
        guard let session else { return }
        do {
            try session.makePlan()
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(
                of: ":", with: "-")
            runFolder = folder.appendingPathComponent(stamp)
            try FileManager.default.createDirectory(
                at: runFolder!, withIntermediateDirectories: true)
            sync()
            say("Saving to \(runFolder!.path)")
        } catch {
            say("Plan failed: \(error)")
        }
    }

    func start(tiles: [Int]? = nil) {
        guard let runFolder else { return }
        paused.value = false
        captureTotal =
            tiles?.count
            ?? tileStates.values.filter {
                if case .done = $0 { return false } else { return true }
            }.count
        captureDone = 0
        captureStarted = Date()
        // Until a tile finishes: the video plus a guess at the move and settle.
        finishAt = Date().addingTimeInterval(Double(captureTotal) * (videoSeconds + 8))
        let paused = self.paused
        let shouldContinue: @Sendable () -> Bool = { !paused.value }
        perform(tiles == nil ? "Capturing" : "Redoing") {
            try await $0.run(tiles: tiles, into: runFolder, shouldContinue: shouldContinue)
        }
    }

    func pause() {
        paused.value = true
        say("Pausing after this tile.")
    }

    func stop() {
        paused.value = true
        try? mount?.stop()
        say("Stop.")
    }

    func redoSelected() {
        guard !selected.isEmpty else { return }
        let tiles = selected.sorted()
        selected = []
        start(tiles: tiles)
    }

    func makePreview() {
        guard let session, let plan = session.plan else { return }
        let preview = MosaicPreview.make(
            plan: plan, stacks: session.stacks, states: session.states)
        self.preview = preview
        previewImage = Imaging.image(
            width: preview.width, height: preview.height, values: preview.pixels)
        let flagged = preview.missing.count + preview.failed.count + preview.soft.count
        say(
            flagged == 0
                ? "Preview: all \(plan.tiles.count) tiles look good."
                : "Preview: \(preview.missing.count) missing, \(preview.failed.count) failed, \(preview.soft.count) soft. Select them and press Redo."
        )
        selected = Set(preview.missing + preview.failed + preview.soft)
    }

    // MARK: - Updates

    private func handle(_ event: MosaicEvent) {
        switch event {
        case .message(let m): say(m)
        case .tile(let id, let state):
            tileStates[id] = state
            switch state {
            case .done, .failed:
                guard finishAt != nil else { break }
                captureDone += 1
                let perTile = Date().timeIntervalSince(captureStarted) / Double(captureDone)
                finishAt = Date().addingTimeInterval(
                    perTile * Double(max(captureTotal - captureDone, 0)))
            default: break
            }
            if case .failed(let why) = state { say("Tile \(id) failed: \(why)") }
        }
    }

    private func sync() {
        guard let session else { return }
        plan = session.plan
        tileStates = session.states
        hereSet = session.here != nil
        calibrated = session.calibration != nil
    }

    private func poll() {
        guard let mount else { return }
        if let s = try? mount.status() {
            mountState = s.state
            altitude = s.altitudeDeg
            for m in s.messages { say(m) }
        }
    }
}

/// Grey images for the screen.
enum Imaging {
    static func image(fromFrame f: Frame) -> CGImage? {
        // 4× binned for speed.
        let (w, h) = (f.width / 4, f.height / 4)
        var out = [UInt8](repeating: 0, count: w * h)
        f.pixels.withUnsafeBufferPointer { p in
            for y in 0..<h {
                for x in 0..<w {
                    var s = 0
                    for dy in 0..<4 {
                        let row = (4 * y + dy) * f.width + 4 * x
                        s += Int(p[row]) + Int(p[row + 1]) + Int(p[row + 2]) + Int(p[row + 3])
                    }
                    out[y * w + x] = UInt8(s / 16)
                }
            }
        }
        return gray(width: w, height: h, bytes: out)
    }

    static func image(width: Int, height: Int, values: [Float]) -> CGImage? {
        gray(
            width: width, height: height,
            bytes: values.map { UInt8(max(0, min(255, $0 * 255))) })
    }

    static func gray(width: Int, height: Int, bytes: [UInt8]) -> CGImage? {
        guard width > 0, height > 0,
            let provider = CGDataProvider(data: Data(bytes) as CFData)
        else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
            bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: 0), provider: provider, decode: nil,
            shouldInterpolate: true, intent: .defaultIntent)
    }
}

/// A flag shared with the background run: pause and stop set it.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        get { lock.withLock { _value } }
        set { lock.withLock { _value = newValue } }
    }
}
