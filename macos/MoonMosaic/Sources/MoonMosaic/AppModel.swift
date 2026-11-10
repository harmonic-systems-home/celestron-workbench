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
    @Published var exposureMs: Double {
        didSet {
            save()
            applyCamera()
        }
    }
    @Published var gain: Int {
        didSet {
            save()
            applyCamera()
        }
    }
    @Published var simulate: Bool { didSet { save() } }
    /// Send this Mac's time and the site to the hand controller on connect.
    @Published var setHandController: Bool { didSet { save() } }
    /// "auto" (red from civil dusk to dawn at the site), "day" or "night".
    @Published var paletteMode: String {
        didSet {
            save()
            updatePalette()
        }
    }
    @Published var folder: URL { didSet { save() } }

    // State.
    /// The red night palette is showing.
    @Published private(set) var isNight = true
    private var paletteCheckedAt = Date.distantPast
    @Published private(set) var connected = false {
        didSet { keepAwake.isOn = connected }
    }
    private let keepAwake = KeepAwake(reason: "Connected to the mount")
    @Published private(set) var mountState = "Not connected"
    @Published private(set) var altitude: Double?
    /// Why the mount is latched, while it is: the app then stops any motion,
    /// the keys' included, until Reset.
    @Published private(set) var latchedReason: String?
    @Published private(set) var busy: String?
    @Published private(set) var log: [String] = []
    @Published private(set) var plan: MosaicPlan?
    @Published private(set) var tileStates: [Int: TileState] = [:]
    @Published private(set) var preview: MosaicPreview?
    @Published private(set) var previewImage: CGImage?
    @Published private(set) var liveImage: CGImage?
    /// The frame's middle at full resolution, its sharpness (averaged over
    /// the last few frames), and the best seen since the last reset.
    @Published private(set) var focusImage: CGImage?
    @Published private(set) var focusSharpness: Double?
    @Published private(set) var bestFocus: Double = 0
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
    private var holdStop: Flag?
    /// The hand controller has stopped answering (or answers slowly): it
    /// may have hung with a motor still running, which only cutting the
    /// mount's power stops. Beeps until silenced.
    @Published private(set) var linkAlarm: LinkAlarm?
    private var alarmBeeps: Timer? { didSet { alarmSounding = alarmBeeps != nil } }
    @Published private(set) var alarmSounding = false
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
        setHandController = d["setHandController"] as? Bool ?? true
        paletteMode = d["paletteMode"] as? String ?? "auto"
        folder =
            (d["folder"] as? String).map { URL(fileURLWithPath: $0) }
            ?? Self.support.appendingPathComponent("sessions")
        save()
        updatePalette()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func save() {
        let d: [String: Any] = [
            "latitude": latitude, "longitude": longitude, "focalLengthMm": focalLengthMm,
            "overlap": overlap, "videoSeconds": videoSeconds, "exposureMs": exposureMs,
            "gain": gain, "simulate": simulate, "setHandController": setHandController, "paletteMode": paletteMode, "folder": folder.path,
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

    /// Night from civil dusk (Sun 6° below the horizon) to dawn at the
    /// site, in auto; with no site yet, night from 19:00 to 07:00.
    private func updatePalette() {
        paletteCheckedAt = Date()
        let night: Bool
        switch paletteMode {
        case "day": night = false
        case "night": night = true
        default:
            let now = Date()
            if siteSet {
                let site = Site(latitudeDeg: latitude, longitudeDeg: longitude)
                night = Ephemeris.horizontal(Ephemeris.sun(at: now), at: now, from: site).altDeg < -6
            } else {
                let hour = Calendar.current.component(.hour, from: now)
                night = hour >= 19 || hour < 7
            }
        }
        if night != isNight { isNight = night }
    }

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
        let setup = setHandController ? (latitudeDeg: latitude, longitudeDeg: longitude) : nil
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(
            of: ":", with: "-")
        let trace = folder.appendingPathComponent("mount-traces")
            .appendingPathComponent("\(stamp).ndjson")
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
                let mount = try MountSession(
                    port: port, safety: ["max_goto_deg": 1.0], trace: trace, setup: setup)
                let camera = SharedCamera(
                    simulate
                        ? FakeCamera(width: 1920, height: 1080, scale: 0.3, rotationDeg: 25)
                        : try ZWOCamera(library: ZWOLibrary()))
                await MainActor.run {
                    self.connected(mount: mount, camera: camera, port: port)
                    self.say("Mount trace: \(trace.lastPathComponent)")
                }
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
        if let s = o.setup {
            say("Hand controller time: \(s.time); site: \(s.location).")
        }
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
        silenceAlarm()
        linkAlarm = nil
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
        latchedReason = nil
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
            let color = camera.info.isColor
            var recentSharpness: [Double] = []
            while !Task.isCancelled {
                // The session's frames while it is reading (a goto's
                // check, a tile's video); otherwise one of our own.
                let recent = camera.latest.map { Date().timeIntervalSince($0.time) < 0.5 }
                if let frame = recent == true ? camera.latest : try? camera.frame(timeoutMs: 500) {
                    let image = Imaging.image(fromFrame: frame)
                    let crop = Focus.crop(frame)
                    let focus = Imaging.image(crop: crop, binned: color)
                    recentSharpness = (recentSharpness + [Focus.sharpness(crop)]).suffix(5)
                    let sharpness = recentSharpness.reduce(0, +) / Double(recentSharpness.count)
                    await MainActor.run {
                        guard let self else { return }
                        self.liveImage = image
                        self.focusImage = focus
                        self.focusSharpness = sharpness
                        self.bestFocus = max(self.bestFocus, sharpness)
                    }
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

    func resetBestFocus() {
        bestFocus = focusSharpness ?? 0
    }

    /// Exposure steps, in milliseconds.
    static let exposures: [Double] = [
        0.1, 0.2, 0.3, 0.5, 0.7, 1, 1.5, 2, 3, 5, 7, 10, 15, 20, 30, 50, 70, 100, 150, 200, 300,
        500, 1000,
    ]

    func stepExposure(_ direction: Int) {
        let steps = Self.exposures
        exposureMs =
            direction > 0
            ? steps.first { $0 > exposureMs + 1e-9 } ?? steps[steps.count - 1]
            : steps.last { $0 < exposureMs - 1e-9 } ?? steps[0]
    }

    func stepGain(_ direction: Int) {
        gain = min(max(gain + 10 * direction, 0), 600)
    }

    /// Exposure and gain to the camera now (for the live view) and to the
    /// session (for its next step).
    private func applyCamera() {
        let (us, g) = (Int(exposureMs * 1000), gain)
        // Brightness changes the sharpness scale: a new best from here.
        bestFocus = 0
        session?.setCamera(exposureUs: us, gain: g)
        guard let camera else { return }
        Task.detached { [weak self] in
            do {
                try camera.configure(exposureUs: us, gain: g)
            } catch {
                await MainActor.run { self?.say("Camera: \(error)") }
            }
        }
    }

    func toggleHold() {
        if holding {
            stopHold()
            return
        }
        // A hold still finishing its last move can't be restarted yet.
        guard let session, hereSet, busy == nil, holdTask == nil else { return }
        holding = true
        say("Holding on the Moon's centre.")
        let stop = Flag()
        holdStop = stop
        holdTask = Task.detached { [weak self] in
            // Ends between moves, never in one: a move cut short leaves the
            // mount going with nobody waiting for it.
            while !stop.value {
                do {
                    try await session.hold()
                } catch {
                    await MainActor.run { self?.say("Hold stopped: \(error)") }
                    break
                }
                for _ in 0..<100 where !stop.value {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
            await MainActor.run {
                guard let self else { return }
                self.holding = false
                self.holdTask = nil
                self.sync()
            }
        }
    }

    /// Asks Hold to end after any move in progress; `holdTask` finishes then.
    private func stopHold() {
        holding = false
        holdStop?.value = true
    }

    /// Clears a latched fault once the mount is still; the next step arms it.
    func resetFault() {
        guard let mount else { return }
        do {
            try mount.reset()
            say("Reset: the keys work again; the next step arms the mount.")
        } catch {
            say("Couldn't reset: \(error)")
        }
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
        if Date().timeIntervalSince(paletteCheckedAt) > 60 { updatePalette() }
        guard let mount else { return }
        if let s = try? mount.status() {
            mountState = s.state
            altitude = s.altitudeDeg
            latchedReason = s.state == "FaultLatched" ? (s.lastFault?.detail ?? "a fault") : nil
            for m in s.messages { say(m) }
            checkLink(s)
        }
    }

    /// Raises the alarm when the hand controller stops answering: the link
    /// is lost, or idle reads (every 2 s, or 4 a second once armed) stop
    /// coming. Reads pause during the app's own moves, so those don't count.
    private func checkLink(_ s: MountSession.Status) {
        let idle = ["ConnectedReadOnly", "Armed", "FaultLatched"].contains(s.state)
        let alarm: LinkAlarm? =
            if s.linkLost { .lost }
            else if idle, let age = s.positionsAgeMs, age > 8000 { .slow(seconds: age / 1000) }
            else { nil }
        switch (linkAlarm, alarm) {
        case (nil, let new?):
            linkAlarm = new
            say("ALARM: \(new.text)")
            alarmBeeps?.invalidate()
            NSSound(named: "Sosumi")?.play()
            alarmBeeps = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
                NSSound(named: "Sosumi")?.play()
            }
        case (.slow?, .lost):
            linkAlarm = .lost
            say("ALARM: \(LinkAlarm.lost.text)")
        case (.slow?, .slow?):
            linkAlarm = alarm
        case (.slow?, nil):
            // Answering again: the reads were only held up.
            linkAlarm = nil
            silenceAlarm()
            say("The hand controller is answering again.")
        default:
            break
        }
    }

    func silenceAlarm() {
        alarmBeeps?.invalidate()
        alarmBeeps = nil
    }

}

enum LinkAlarm: Equatable {
    case slow(seconds: Int)
    case lost

    var text: String {
        switch self {
        case .slow(let seconds):
            "The hand controller hasn't answered for \(seconds) s. If the mount is moving and its keys don't stop it, cut the mount's power now."
        case .lost:
            "The hand controller stopped answering. If the mount is moving, cut its power now. Then Disconnect, unplug and re-plug the hand controller's USB, power the mount on and Connect."
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

    /// A crop at full resolution, or 2× binned for a colour camera (so its
    /// Bayer pattern doesn't show).
    static func image(crop f: Frame, binned: Bool) -> CGImage? {
        guard binned else { return gray(width: f.width, height: f.height, bytes: f.pixels) }
        let (w, h) = (f.width / 2, f.height / 2)
        var out = [UInt8](repeating: 0, count: w * h)
        f.pixels.withUnsafeBufferPointer { p in
            for y in 0..<h {
                for x in 0..<w {
                    let i = 2 * y * f.width + 2 * x
                    out[y * w + x] = UInt8(
                        (Int(p[i]) + Int(p[i + 1]) + Int(p[i + f.width]) + Int(p[i + f.width + 1]))
                            / 4)
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
