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
    /// The survey that finds the Moon's centre (ADR 0019, amendment 1).
    @Published var surveyExposureMs: Double {
        didSet {
            save()
            applySurvey()
        }
    }
    @Published var surveyGain: Int {
        didSet {
            save()
            applySurvey()
        }
    }
    @Published var simulate: Bool { didSet { save() } }
    /// The simulated camera with the real mount (ADR 0022 amendment 7): the
    /// encoders point the simulated camera, so tracking, nudges and moves are
    /// tested for real, in daylight or cloud.
    @Published var simulatedCamera: Bool { didSet { save() } }
    /// The simulator's controls (its own window).
    let simulator = SimulatorModel()
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
    /// Search (ADR 0022): the pattern to run, and its coarseness. The step can
    /// be wider than the frame — the Moon's glow shows before its disk.
    @Published var searchPattern: SearchPattern { didSet { save() } }
    @Published var searchStepDeg: Double { didSet { save() } }
    @Published var searchReachDeg: Double { didSet { save() } }
    /// Test mode (ADR 0022): find a fixed target (the drainpipe) to exercise
    /// the search patterns and focus with no tracking. The reference altitude
    /// ties the encoder to the sky for the envelope, since there's no Moon to
    /// take it from — set the tube roughly there first.
    @Published var testMode: Bool {
        didSet {
            save()
            // Swap the simulated target (drifting Moon ↔ fixed drainpipe) so
            // the toggle dry-runs too.
            if connected, simulate { installSimProvider() }
        }
    }
    @Published var testAltitudeDeg: Double { didSet { save() } }
    /// The sky the search looks against ("auto": day while the Sun is up,
    /// else a clear night); each has its own trigger (Blob.Sky).
    @Published var searchSky: String { didSet { save() } }
    var effectiveSky: Blob.Sky {
        if let s = Blob.Sky(rawValue: searchSky) { return s }
        let site = Site(latitudeDeg: latitude, longitudeDeg: longitude)
        let t = sessionNow
        let sunAlt = Ephemeris.horizontal(Ephemeris.sun(at: t), at: t, from: site).altDeg
        return sunAlt > -6 ? .day : .clearNight
    }

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
    @Published private(set) var battery: MountSession.Battery?
    /// "~60%, about 3 h left", or "Charging, 10.17 V".
    @Published private(set) var batterySummary: String?
    /// Kept across reconnects, so the projection keeps its history.
    private var gauge = BatteryGauge()
    private var lastBatteryReadAt: Date?
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
    /// The live frame's brightness: peak, mean, clipped, lit, Moon in view.
    @Published private(set) var frameStats: FrameStats?
    /// The running (or last) search's pattern and progress, for its map.
    @Published private(set) var searchProgress: SearchProgress?
    /// The mount's axis positions (degrees), as last read.
    @Published private(set) var positionDeg: [Double]?
    /// The mount's tracking rates while it tracks (deg/s), else nil.
    @Published private(set) var mountTrackingRates: [Double]?

    /// What the mount is doing about the sky, for the status line:
    /// tracking, drifting (tracking paused on purpose), moving, or not.
    var trackingStatus: (symbol: String, text: String, kind: Int) {
        if mountState == "Moving" || mountState == "Stopping" { return ("arrow.up.and.down.and.arrow.left.and.right", "Moving", 2) }
        if let r = mountTrackingRates {
            let rate = hypot(r[0], r[1]) * 3600
            return ("scope", following ? String(format: "Tracking, following (%.0f″/s)", rate) : String(format: "Tracking (%.0f″/s)", rate), 0)
        }
        if busy == "Orienting camera" { return ("wind", "Drifting: tracking paused to measure", 1) }
        return ("pause.circle", "Not tracking", 3)
    }
    /// The frame's middle at full resolution, its sharpness (averaged over
    /// the last few frames), and the best seen since the last reset.
    @Published private(set) var focusImage: CGImage?
    @Published private(set) var focusSharpness: Double?
    @Published private(set) var bestFocus: Double = 0
    /// A rolling sharpness trace for the focus line graph (ADR 0022), and
    /// whether the image has settled (touch-shake gone, only seeing left).
    @Published private(set) var focusHistory: [FocusAssist.Sample] = []
    @Published private(set) var focusSettled = false
    @Published private(set) var hereSet = false
    @Published private(set) var calibrated = false
    @Published private(set) var centreFound = false
    @Published private(set) var darkTiles = 0
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
    /// Follow mode (ADR 0022 amendment 7): tracking from Track on, nudges
    /// stay, Undo goes back.
    @Published private(set) var following = false
    @Published private(set) var undoDepth = 0
    private var followTask: Task<Void, Never>?
    private var followStop: Flag?
    /// The guided flow's steps: which are done, which is running, and each
    /// automated step's time against its estimate.
    @Published private(set) var flowDone: Set<FlowStep> = []
    @Published private(set) var flowActive: FlowStep?
    /// Asks the main window to show the mosaic preview (after a capture).
    @Published var showPreviewRequest = 0
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
    /// This connection's setup folder: the whole log, calibration and survey frames.
    private var setupFolder: URL?
    private var runFolder: URL?
    private let paused = Flag()
    /// Per-frame sharpness, shake state and history for the focus assist
    /// (ADR 0022). Fed from the live loop, read by the focus line graph.
    private let focusAid = FocusAssist()
    private var liveTask: Task<Void, Never>?
    private var pollTimer: Timer?
    /// Simulate-only fake-sky anchor (ADR 0022 dry-run): where the tube
    /// started, when it connected, and the rehearsal clock. The live view's
    /// target sits off this, so the search has something to hunt for.
    private var simStart: [Double]?
    private var simConnect: Date?
    private var simClock: (@Sendable () -> Date)?

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
        surveyExposureMs = d["surveyExposureMs"] as? Double ?? 100
        surveyGain = d["surveyGain"] as? Int ?? 300
        simulate = d["simulate"] as? Bool ?? false
        simulatedCamera = d["simulatedCamera"] as? Bool ?? false
        setHandController = d["setHandController"] as? Bool ?? true
        paletteMode = d["paletteMode"] as? String ?? "auto"
        folder =
            (d["folder"] as? String).map { URL(fileURLWithPath: $0) }
            ?? Self.support.appendingPathComponent("sessions")
        searchPattern = SearchPattern(rawValue: d["searchPattern"] as? String ?? "") ?? .spiral
        searchStepDeg = d["searchStepDeg"] as? Double ?? 0.3
        searchReachDeg = d["searchReachDeg"] as? Double ?? 2.0
        testMode = d["testMode"] as? Bool ?? false
        testAltitudeDeg = d["testAltitudeDeg"] as? Double ?? 10
        searchSky = d["searchSky"] as? String ?? "auto"
        save()
        updatePalette()
        simulator.onSkyChanged = { [weak self] in self?.reinstallSimulatedSky() }
        simulator.onSpeedChanged = { [weak self] k in self?.applySimSpeed(k) }
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    private func save() {
        let d: [String: Any] = [
            "latitude": latitude, "longitude": longitude, "focalLengthMm": focalLengthMm,
            "overlap": overlap, "videoSeconds": videoSeconds, "exposureMs": exposureMs,
            "gain": gain, "surveyExposureMs": surveyExposureMs, "surveyGain": surveyGain,
            "simulate": simulate, "simulatedCamera": simulatedCamera, "setHandController": setHandController, "paletteMode": paletteMode, "folder": folder.path,
            "searchPattern": searchPattern.rawValue, "searchStepDeg": searchStepDeg,
            "searchReachDeg": searchReachDeg, "testMode": testMode, "testAltitudeDeg": testAltitudeDeg, "searchSky": searchSky,
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

    /// When the app opened, naming its log file (local time, sortable).
    private static let launchStamp: String = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd_HHmmss"
        return f.string(from: Date())
    }()

    func say(_ text: String) {
        let stamp = Self.clock.string(from: Date())
        log.append("\(stamp)  \(text)")
        if log.count > 300 { log.removeFirst(log.count - 300) }
        let line = Data("\(stamp)  \(text)\n".utf8)
        // Every on-screen message also goes to this launch's log, from the
        // moment the app opens, connected or not.
        let launchLog = folder.appendingPathComponent("logs")
            .appendingPathComponent("\(Self.launchStamp).txt")
        try? FileManager.default.createDirectory(
            at: launchLog.deletingLastPathComponent(), withIntermediateDirectories: true)
        for url in [runFolder, setupFolder].compactMap({ $0?.appendingPathComponent("log.txt") }) + [launchLog] {
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
        let simCamera = simulate || simulatedCamera
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
                    port: port, safety: attendedSafety, trace: trace, setup: setup)
                let camera = SharedCamera(
                    simCamera
                        ? SimCamera(optics: .sct8, scene: MoonScene.synthetic(size: 1024))
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
        settings.surveyExposureUs = Int(surveyExposureMs * 1000)
        settings.surveyGain = surveyGain
        // Rehearsing: the clock runs from the next time the Moon is high here.
        let realTime: @Sendable () -> Date = { Date() }
        let clock = simulate ? Self.rehearsalClock(site: site) : realTime
        let session = MosaicSession(
            mount: mount, camera: camera, settings: settings, clock: clock,
            onEvent: { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            })
        // Everything from connect on: the log and the calibration and survey
        // frames, so a failed setup can be studied later.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let setup = folder.appendingPathComponent("setup-\(stamp)")
        try? FileManager.default.createDirectory(at: setup, withIntermediateDirectories: true)
        session.diagnostics = setup
        setupFolder = setup
        self.session = session
        if camera.camera is SimCamera {
            // The fake sky keys off the real mount position with an off-centre
            // target, so the whole search dry-runs with no scope (ADR 0022).
            simStart = mount.opened.positionsDeg
            simConnect = clock()
            simClock = clock
            installSimProvider()
        }
        connected = true
        flowDone = [.connect]
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
        searchStop.value = true
        searching = false
        searchTask = nil
        stopHold()
        stopLive()
        try? mount?.stop()
        simStart = nil
        simConnect = nil
        simClock = nil
        simulator.detach()
        pauseFollow()
        followTask = nil
        flowDone = []
        flowActive = nil
        session = nil
        camera = nil
        mount = nil
        connected = false
        hereSet = false
        calibrated = false
        centreFound = false
        darkTiles = 0
        mountState = "Not connected"
        battery = nil
        batterySummary = nil
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
            while !Task.isCancelled {
                // The session's frames while it is reading (a goto's
                // check, a tile's video); otherwise one of our own.
                let recent = camera.latest.map { Date().timeIntervalSince($0.time) < 0.5 }
                if let frame = recent == true ? camera.latest : try? camera.frame(timeoutMs: 500) {
                    let image = Imaging.image(fromFrame: frame)
                    let focus = Imaging.image(crop: Focus.crop(frame), binned: color)
                    let sky = await MainActor.run { self?.effectiveSky ?? .clearNight }
                    let stats = FrameStats(frame, sky: sky)
                    await MainActor.run {
                        guard let self else { return }
                        self.frameStats = stats
                        // Score, shake-gate and record this frame (ADR 0022).
                        let sample = self.focusAid.add(frame)
                        self.liveImage = image
                        self.focusImage = focus
                        self.focusSharpness = sample.sharpness
                        self.focusSettled = sample.settled
                        self.focusHistory = self.focusAid.history
                        self.bestFocus = self.focusAid.settledBest?.sharpness ?? self.bestFocus
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

    /// Installs the fake sky the live view renders in simulate mode (ADR 0022
    /// dry-run). The target sits off where the tube started — far enough to be
    /// out of frame — so the search must hunt and click-to-recentre visibly
    /// walks it in. For the Moon it drifts with the ephemeris, so Here,
    /// calibrate and the mosaic rehearse exactly as before; the test-mode
    /// "drainpipe" is a fixed terrestrial target that doesn't drift.
    private func installSimProvider() {
        let fake = camera?.camera as? FakeCamera
        let sim = camera?.camera as? SimCamera
        guard fake != nil || sim != nil,
            let start = simStart, let connect = simConnect, let clock = simClock,
            let mount
        else { return }
        let site = Site(latitudeDeg: latitude, longitudeDeg: longitude)
        let test = testMode
        let fixedAlt = testAltitudeDeg
        // Off-centre at connect, within the search reach and out of frame
        // (the simulator window can move it, or pick it at random).
        let offset = simulator.moonOffsetDeg
        let anchorAz = start[0] + offset.az
        let anchorAlt = start[1] + offset.alt
        if let sim {
            // Tonight's Moon size (the simulator window sets the scene).
            sim.moonRadiusArcsec = Ephemeris.moon(at: clock(), from: site).diameterDeg * 1800
        }
        let truth = simulator.truth
        let provider: @Sendable () -> (x: Double, y: Double) = { [weak mount] in
            guard let p = try? mount?.status().positionsDeg else { return (1e6, 1e6) }
            var targetAz = anchorAz
            var targetAlt = anchorAlt
            let altForCos: Double
            if test {
                altForCos = fixedAlt
            } else {
                let now = clock()
                let m0 = Ephemeris.moon(at: connect, from: site).horizontal
                let mNow = Ephemeris.moon(at: now, from: site).horizontal
                targetAz += wrap180app(mNow.azDeg - m0.azDeg)
                targetAlt += mNow.altDeg - m0.altDeg
                altForCos = mNow.altDeg
            }
            truth.set(mount: p, moon: [targetAz, targetAlt])
            let dAz = wrap180app(p[0] - targetAz) * cos(altForCos * .pi / 180) * 3600
            let dAlt = (p[1] - targetAlt) * 3600
            return (dAz, dAlt)
        }
        fake?.provider = provider
        sim?.provider = provider
        if let sim { simulator.attach(sim, site: site, clock: clock, reachDeg: searchReachDeg) }
        if simulate, simulator.speed != 1 { applySimSpeed(simulator.speed) }
    }

    /// The session's time (the rehearsal clock when simulating).
    var sessionNow: Date { session?.now ?? Date() }

    /// Rehearsal speed (simulated mount only).
    func applySimSpeed(_ k: Double) {
        guard simulate, let mount else { return }
        do {
            try mount.setSimSpeed(k)
            session?.setTimeScale(k)
        } catch {
            say("Couldn't set the simulation speed: \(error)")
        }
    }

    /// Re-aims the simulated Moon (after the simulator window changes it).
    func reinstallSimulatedSky() {
        if connected, camera?.camera is SimCamera { installSimProvider() }
    }

    // MARK: - Steps

    /// Runs an operation off the main thread; the live view carries on.
    /// With `resumeHold`, a Hold that was on before the step comes back on
    /// after it succeeds, so the Moon isn't left to drift out of the frame.
    /// With `holdAfter`, Hold starts after it succeeds either way.
    private func perform(
        _ name: String, step: FlowStep? = nil, resumeHold: Bool = false, holdAfter: Bool = false,
        _ body: @escaping @Sendable (MosaicSession) async throws -> Void
    ) {
        guard let session, busy == nil else { return }
        busy = name
        // A step takes over the mount: Hold and Follow end, after any move
        // in progress; Follow comes back afterwards.
        let hold = holdTask
        let wasHolding = holding
        stopHold()
        let follow = followTask
        let wasFollowing = following
        pauseFollow()
        let started = Date()
        if let step { flowActive = step }
        Task.detached { [weak self] in
            await hold?.value
            await follow?.value
            var ok = true
            do {
                try await body(session)
            } catch {
                ok = false
                await MainActor.run { self?.say("\(name) failed: \(error)") }
            }
            await MainActor.run {
                guard let self else { return }
                self.busy = nil
                self.finishAt = nil
                self.sync()
                if ok && ((resumeHold && wasHolding) || holdAfter) && !self.holding {
                    self.toggleHold()
                }
                if wasFollowing && !self.holding && !self.following { self.startFollow() }
                if let step {
                    if self.flowActive == step { self.flowActive = nil }
                    if ok { self.flowDone.insert(step) }
                    self.logStepTime(step, Date().timeIntervalSince(started), ok: ok)
                }
            }
        }
    }

    /// Each step's time against its designed estimate (amendment 7's time
    /// budget), in the log, so the estimates can be checked.
    private func logStepTime(_ step: FlowStep, _ seconds: Double, ok: Bool) {
        guard let estimate = step.estimateSeconds else { return }
        let d = seconds - estimate
        say(
            String(
                format: "%@ %@ in %.0f s (estimate %.0f s, %@%.0f s).", step.title, ok ? "done" : "stopped",
                seconds, estimate, d >= 0 ? "+" : "−", abs(d)))
    }

    // MARK: - Follow (ADR 0022 amendment 7)

    /// Track / Stop Tracking.
    func toggleTrack() {
        if following || followTask != nil {
            stopFollow()
        } else {
            guard connected, busy == nil, !testMode else { return }
            stopHold()
            let hold = holdTask
            Task { @MainActor [weak self] in
                await hold?.value
                self?.startFollow()
                self?.say("Tracking the Moon. Nudge with the arrows or the hand controller; Undo goes back.")
            }
        }
    }

    private func startFollow() {
        guard let session, followTask == nil else { return }
        // Before any search or Here, the encoder's altitude is tied to the
        // sky from the Moon's computed altitude: the spotting scope is on it.
        if let mount, (try? mount.status().altitudeDeg) == nil {
            let alt = Ephemeris.moon(at: session.now, from: Site(latitudeDeg: latitude, longitudeDeg: longitude))
                .horizontal.altDeg
            try? mount.setAltitudeReference(alt)
        }
        following = true
        flowDone.insert(.track)
        let stop = Flag()
        followStop = stop
        followTask = Task.detached { [weak self] in
            do {
                try await session.runFollow(cancelled: { stop.value })
            } catch {
                await MainActor.run { self?.say("Tracking stopped: \(error)") }
            }
            await MainActor.run {
                guard let self else { return }
                self.followTask = nil
                if self.followStop === stop { self.following = false }
            }
        }
    }

    /// Ends the follow loop but leaves the mount tracking (a step takes over).
    private func pauseFollow() {
        followStop?.value = true
        following = false
    }

    /// Stop Tracking: the loop ends, then the mount stops.
    private func stopFollow() {
        pauseFollow()
        let task = followTask
        let mount = self.mount
        Task.detached {
            await task?.value
            try? mount?.stopTracking()
        }
        say("Tracking stopped.")
    }

    /// Ends a nudge (app or hand controller); tracking carries on.
    func stopNudge() {
        guard following, let session else { return }
        session.followStop()
    }

    /// Back to where the scope was against the Moon before the last nudge.
    func undo() {
        guard following, let session else { return }
        session.followUndo()
    }

    /// The operator marks a by-hand step (camera settings, focus) done.
    func markDone(_ step: FlowStep) {
        if flowDone.contains(step) { flowDone.remove(step) } else { flowDone.insert(step) }
    }

    func resetBestFocus() {
        focusAid.reset()
        focusHistory = []
        focusSettled = false
        bestFocus = 0
    }

    // MARK: - Search (ADR 0022)

    /// The operator has the target in view ("I see it"), to end the search
    /// where it is; and a plain stop. Either ends it between stops.
    private let sawTarget = Flag()
    private let searchStop = Flag()
    @Published private(set) var searching = false
    private var searchTask: Task<Void, Never>?
    /// A recentre is taking over from a search: it keeps `busy` while the old
    /// search winds down, so no other step slips in during the slew.
    private var recentring = false

    /// Runs the chosen search (ADR 0022): an expanding square spiral, or a
    /// serpentine raster, of short self-terminating gotos from where the
    /// spotting scope left the mount, watching each frame's brightest blob.
    /// Attended and minimal — one goto per stop, no latched-runaway path. It
    /// ends at a bright target, at "I see it", at Stop, or at the pattern's
    /// end. In test mode nothing stops it automatically (a daytime drainpipe
    /// isn't a bright blob): the operator flags it with "I see it".
    func startSearch() {
        guard let session, connected, busy == nil, !searching else { return }
        let pattern = searchPattern
        let test = testMode
        let (step, reach) = (max(searchStepDeg, 0.02), max(searchReachDeg, searchStepDeg))
        // The reference altitude for the envelope: the Moon's computed altitude
        // (the spotting scope is on it), or the test target's rough altitude.
        let refAlt =
            test
            ? testAltitudeDeg
            : Ephemeris.moon(
                at: session.now, from: Site(latitudeDeg: latitude, longitudeDeg: longitude)
            ).horizontal.altDeg
        searchStop.value = false
        sawTarget.value = false
        searching = true
        busy = "Searching"
        say(
            test
                ? "Test search (\(pattern.rawValue)): finding the target; tracking off. Use “I see it”."
                : "\(pattern.rawValue.capitalized) search: hunting for the Moon; \(step)° step, \(reach)° reach."
        )
        runSearch(session, pattern: pattern, test: test, step: step, reach: reach, refAlt: refAlt)
    }

    /// Drives one search off the main thread, then reports and tidies up.
    private func runSearch(
        _ session: MosaicSession, pattern: SearchPattern, test: Bool,
        step: Double, reach: Double, refAlt: Double
    ) {
        let (stop, saw) = (searchStop, sawTarget)
        // "I see it" isn't a stop: the search goes back to where the target
        // was seen (MosaicSession.backtrack).
        let cancelled: @Sendable () -> Bool = { stop.value }
        let sighted: @Sendable () -> Bool = { saw.value }
        // Automatic acquisition: a clearly bright region against dark sky.
        // Off in test mode, where the operator flags the target by eye.
        let found: @Sendable (Blob.Found?) -> Bool
        if test {
            found = { _ in false }
        } else {
            let sky = effectiveSky
            found = { Blob.looksLikeMoon($0, sky: sky) }
        }
        // Automatic acquisition then steps onto the disk (track 2, 2c): the
        // first frame that passes is often only glow or a sliver of limb.
        let converge: MosaicSession.Converge? = test ? nil : MosaicSession.Converge()
        let hold = holdTask
        stopHold()
        // The search moves the mount itself: Follow pauses and comes back
        // after it. With the Moon, the pattern rides on its motion.
        let follow = followTask
        if following { resumeFollowAfterSearch = true }
        pauseFollow()
        session.searchFollowsMoon = !test
        searchStarted = Date()
        flowActive = .find
        searchTask = Task.detached { [weak self] in
            await hold?.value
            await follow?.value
            do {
                let outcome: MosaicSession.SearchOutcome
                switch pattern {
                case .spiral:
                    outcome = try await session.searchSpiral(
                        stepDeg: step, reachDeg: reach, referenceAltitudeDeg: refAlt,
                        converge: converge, found: found, cancelled: cancelled, sighted: sighted)
                case .raster:
                    outcome = try await session.searchRaster(
                        halfWidthDeg: reach, halfHeightDeg: reach * 0.6, rowSpacingDeg: step,
                        captureStepDeg: step, referenceAltitudeDeg: refAlt,
                        converge: converge, found: found, cancelled: cancelled, sighted: sighted)
                }
                await MainActor.run { self?.searchFinished(outcome, byOperator: saw.value) }
            } catch {
                await MainActor.run {
                    self?.say("Search failed: \(error)")
                    self?.searchEnded()
                }
            }
        }
    }

    private func searchFinished(_ outcome: MosaicSession.SearchOutcome, byOperator: Bool) {
        // A recentre superseded this search: it logs and keeps the mount.
        if recentring {
            searchEnded()
            return
        }
        if byOperator && !outcome.found {
            say("Marked in view after \(outcome.stops) stops; search stopped.")
        } else if outcome.found, let b = outcome.blob {
            if outcome.convergeSteps == 0 && outcome.converged {
                say(String(format: "Found the Moon after %d stops, on the disk (%.0f%% lit). ", outcome.stops, b.brightFraction * 100))
            } else if outcome.converged {
                say(
                    String(
                        format: "Found the Moon after %d stops and stepped onto the disk in %d moves (%.0f%% lit).",
                        outcome.stops, outcome.convergeSteps, b.brightFraction * 100))
            } else {
                say(
                    String(
                        format: "Sighted the Moon after %d stops but couldn't step onto the disk (%.0f%% lit). Centre it by hand before Here.",
                        outcome.stops, b.brightFraction * 100))
            }
        } else {
            say("Search finished (\(outcome.stops) stops) without a clear target.")
        }
        // Only a search that ended on the disk counts as found (and ties the
        // encoders to the sky); a sighting it couldn't step onto doesn't.
        let found = outcome.found && outcome.converged
        if flowActive == .find { flowActive = nil }
        if found { flowDone.insert(.find) }
        logStepTime(.find, Date().timeIntervalSince(searchStarted), ok: found)
        searchEnded()
        if resumeFollowAfterSearch {
            resumeFollowAfterSearch = false
            startFollow()
        }
        // Landing on the disk ties the encoders to the sky: Here happens by
        // itself (amendment 7: no separate Here step).
        if found && !testMode { here() }
    }
    private var resumeFollowAfterSearch = false
    private var searchStarted = Date()

    private func searchEnded() {
        searching = false
        searchTask = nil
        // A recentre holds `busy` ("Recentring") across the handover.
        if !recentring { busy = nil }
        sync()
    }

    /// Operator flag: the target is in view — stop the search here.
    func sawIt() {
        guard searching else { return }
        sawTarget.value = true
        say("Marked: target in view.")
    }

    /// Stop the running search, between stops (never mid-move).
    func stopSearch() {
        guard searching else { return }
        searchStop.value = true
        say("Stopping search.")
    }

    /// Click-to-recentre (ADR 0022): the operator clicked a spot in the live
    /// image. `fraction` is that spot from the frame's centre, each axis in
    /// −0.5…0.5 of the displayed image (x right, y down). Slew it to the
    /// centre, then start a finer search there to settle the target in.
    func recentre(fraction: CGSize) {
        // A recentre may interrupt a running search, but not capture or any
        // other step.
        guard let session, connected, busy == nil || searching else { return }
        let px = PixelOffset(
            x: Double(fraction.width) * Double(session.camera.info.width),
            y: Double(fraction.height) * Double(session.camera.info.height))
        // Hand off any running search cleanly, then recentre and go finer.
        let running = searchTask
        if searching { searchStop.value = true }
        let test = testMode
        let (step, reach) = (max(searchStepDeg / 2, 0.02), max(searchReachDeg / 2, searchStepDeg))
        let refAlt =
            test
            ? testAltitudeDeg
            : Ephemeris.moon(
                at: session.now, from: Site(latitudeDeg: latitude, longitudeDeg: longitude)
            ).horizontal.altDeg
        say("Recentring on the clicked point, then a finer search there.")
        recentring = true
        busy = "Recentring"
        searching = false
        let hold = holdTask
        stopHold()
        Task.detached { [weak self] in
            await running?.value
            await hold?.value
            do {
                try await session.recentre(pixelOffset: px)
                await MainActor.run {
                    guard let self else { return }
                    self.recentring = false
                    self.searchStop.value = false
                    self.sawTarget.value = false
                    self.searching = true
                    self.busy = "Searching"
                    self.runSearch(
                        session, pattern: self.searchPattern, test: test,
                        step: step, reach: reach, refAlt: refAlt)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.recentring = false
                    self.say("Recentre failed: \(error)")
                    self.searchEnded()
                }
            }
        }
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
        focusAid.reset()
        focusHistory = []
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
        if following { pauseFollow() }
        holding = true
        say(
            session.aimOffset.x == 0 && session.aimOffset.y == 0
                ? "Holding on the Moon's centre." : "Holding at the panned aim.")
        let stop = Flag()
        holdStop = stop
        let wake = holdWake
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
                for _ in 0..<100 where !stop.value && !wake.value {
                    try? await Task.sleep(for: .milliseconds(100))
                }
                wake.value = false
            }
            await MainActor.run {
                guard let self else { return }
                self.holding = false
                self.holdTask = nil
                self.sync()
            }
        }
    }

    /// Re-aims Hold at once (after a pan) instead of at its next 10 s tick.
    private let holdWake = Flag()

    /// GUI pan (2026-11-19): moves the view by a fraction of the frame,
    /// `fx` right and `fy` down, so the point there comes to the centre.
    /// With Here set it shifts Hold's aim and holds there (Calibrate starts
    /// from it too); before Here it is one bounded slew. Never the hand
    /// controller's arrow keys, which can run away.
    func pan(_ fx: Double, _ fy: Double) {
        guard let session, connected else { return }
        let px = PixelOffset(
            x: fx * Double(session.camera.info.width), y: fy * Double(session.camera.info.height))
        if following {
            // Follow: a nudge on top of tracking; it stays, and Undo returns.
            session.followNudge(session.panSky(for: px))
            return
        }
        if hereSet {
            let d = session.panSky(for: px)
            session.aimOffset = SkyOffset(x: session.aimOffset.x + d.x, y: session.aimOffset.y + d.y)
            say(
                String(
                    format: "Pan: aiming %.0f″ right, %.0f″ up of the Moon's centre.",
                    session.aimOffset.x, session.aimOffset.y))
            if holding {
                holdWake.value = true
            } else if busy == nil {
                toggleHold()
            }
        } else if busy == nil {
            perform("Panning") { try await $0.recentre(pixelOffset: px) }
        }
    }

    /// Back to aiming at the Moon's centre.
    func centreAim() {
        guard let session else { return }
        session.aimOffset = SkyOffset(x: 0, y: 0)
        say("Pan: back to the Moon's centre.")
        if holding { holdWake.value = true } else if busy == nil, hereSet { toggleHold() }
    }

    /// Asks Hold to end after any move in progress; `holdTask` finishes then.
    private func stopHold() {
        holding = false
        holdStop?.value = true
        // Hold tracks; releasing it stops the mount (a step's arm would too).
        if let mount, holdTask != nil {
            let hold = holdTask
            Task.detached {
                await hold?.value
                try? mount.stopTracking()
            }
        }
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
        perform("Here", resumeHold: true) { try await $0.markHere() }
    }

    func calibrate() {
        perform("Orienting camera", step: .orientCamera) { try await $0.orientCamera() }
    }

    func findCentre() {
        perform("Finding the centre", step: .orientMoon, resumeHold: true) { try await $0.findCentre() }
    }

    private func applySurvey() {
        session?.setSurvey(exposureUs: Int(surveyExposureMs * 1000), gain: surveyGain)
    }

    /// The dark tiles, at the exposure and gain set now (turn them up for
    /// earthshine first).
    func startEarthshine() {
        guard let session else { return }
        let tiles = session.darkTilesToDo
        guard !tiles.isEmpty else { return }
        say("Earthshine: \(tiles.count) dark tiles at the current exposure and gain.")
        start(tiles: tiles)
    }

    /// When the operator was warned that planning has no centre fit; a
    /// second press soon after plans around Here anyway.
    private var uncentredPlanWarnedAt: Date?

    func makePlan() {
        guard let session else { return }
        let confirmed = uncentredPlanWarnedAt.map { Date().timeIntervalSince($0) < 30 } ?? false
        if session.centreFit == nil && !confirmed {
            uncentredPlanWarnedAt = Date()
            say(
                "Find centre hasn't succeeded: the plan would be centred on Here, which may be off the Moon's centre (on 2026-11-17 it put the grid 3 rows high). Run 3 Find centre, or press Plan again within 30 s to plan around Here anyway."
            )
            return
        }
        uncentredPlanWarnedAt = nil
        do {
            try session.makePlan(allowWithoutCentre: true)
            let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(
                of: ":", with: "-")
            runFolder = folder.appendingPathComponent(stamp)
            try FileManager.default.createDirectory(
                at: runFolder!, withIntermediateDirectories: true)
            sync()
            flowDone.insert(.plan)
            say("Saving to \(runFolder!.path)")
            let need = Int64(session.plan?.tiles.count ?? 0) * bytesPerTile()
            if let free = freeBytes(at: runFolder!) {
                say(
                    String(
                        format: "Disk: this run needs about %.1f GB; %.1f GB free%@",
                        Double(need) / 1e9, Double(free) / 1e9,
                        need > free ? ". NOT ENOUGH SPACE: free some up before Start." : "."))
            }
        } catch {
            say("Plan failed: \(error)")
        }
    }

    /// The low-disk warning on screen, with the tiles Start was asked for;
    /// the operator can capture anyway (the estimate may be wrong).
    @Published var diskWarning: String?
    private var diskWarningTiles: [Int]?

    /// Free space where `url` lives, in bytes.
    private func freeBytes(at url: URL) -> Int64? {
        let v = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    /// One tile's video: raw 8-bit frames at up to about 80 a second
    /// (2026-11-19: 231 frames, 479 MB, for 3 s of 1920×1080).
    private func bytesPerTile() -> Int64 {
        let info = session?.camera.info
        let frame = Int64((info?.width ?? 1920) * (info?.height ?? 1080))
        return frame * Int64((80 * videoSeconds).rounded(.up)) + 1_000_000
    }

    /// "Capture anyway" on the low-disk warning.
    func startDespiteDisk() {
        let tiles = diskWarningTiles
        diskWarning = nil
        diskWarningTiles = nil
        start(tiles: tiles, checkDisk: false)
    }

    func start(tiles: [Int]? = nil, checkDisk: Bool = true) {
        guard let runFolder else { return }
        let toShoot =
            tiles?.count
            ?? tileStates.values.filter {
                if case .done = $0 { return false } else { return true }
            }.count
        // 2026-11-19: the disk filled mid-run and the last tiles were lost.
        let need = Int64(toShoot) * bytesPerTile()
        if checkDisk, let free = freeBytes(at: runFolder), need > free {
            let text = String(
                format:
                    "%d tiles need about %.1f GB, and only %.1f GB is free: about %d tiles would fit. Free some space (or pick another folder in Settings), or capture anyway.",
                toShoot, Double(need) / 1e9, Double(free) / 1e9, Int(free / bytesPerTile()))
            say("Not enough disk space: " + text)
            diskWarningTiles = tiles
            diskWarning = text
            return
        }
        paused.value = false
        captureTotal = toShoot
        captureDone = 0
        captureStarted = Date()
        // Until a tile finishes: the video plus a guess at the move and settle.
        finishAt = Date().addingTimeInterval(Double(captureTotal) * (videoSeconds + 8))
        let paused = self.paused
        let shouldContinue: @Sendable () -> Bool = { !paused.value }
        // Afterwards Hold re-centres on the Moon and keeps it there, ready
        // for another run without finding it again.
        perform(tiles == nil ? "Capturing" : "Redoing", step: .start, holdAfter: true) { [weak self] in
            try await $0.run(tiles: tiles, into: runFolder, shouldContinue: shouldContinue)
            await MainActor.run {
                guard let self else { return }
                // Done: show the mosaic.
                self.makePreview()
                self.showPreviewRequest += 1
            }
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
        case .search(let p): searchProgress = p
        }
    }

    private func sync() {
        guard let session else { return }
        plan = session.plan
        tileStates = session.states
        hereSet = session.here != nil
        calibrated = session.calibration != nil
        centreFound = session.centreFit != nil
        darkTiles = session.darkTilesToDo.count
    }

    private func poll() {
        if Date().timeIntervalSince(paletteCheckedAt) > 60 { updatePalette() }
        guard let mount else { return }
        if let s = try? mount.status() {
            mountState = s.state
            altitude = s.altitudeDeg
            positionDeg = s.positionsDeg
            mountTrackingRates = s.tracking
            undoDepth = session?.follow.undoDepth ?? 0
            if let b = s.battery { checkBattery(b) }
            latchedReason = s.state == "FaultLatched" ? (s.lastFault?.detail ?? "a fault") : nil
            for m in s.messages { say(m) }
            checkLink(s)
        }
    }

    /// Warns once each time the battery's level byte falls to 1, and sounds
    /// once at 0: on 2026-11-09 it read 2, then 1 for the last hours before
    /// the mount went flat.
    private func checkBattery(_ b: MountSession.Battery) {
        let before = battery?.level
        battery = b
        // Status is asked often; the battery is read every 30 s.
        let readAt = Date().addingTimeInterval(-Double(b.ageMs) / 1000)
        if lastBatteryReadAt.map({ abs(readAt.timeIntervalSince($0)) > 2 }) ?? true {
            lastBatteryReadAt = readAt
            gauge.add(.init(at: readAt, volts: b.volts, charging: b.state == 2))
            batterySummary = gauge.summary
        }
        guard let before, b.level < before else { return }
        let volts = String(format: "%.2f V", b.volts)
        if b.level <= 0 {
            say("ALARM: the mount's battery is nearly flat (\(volts)). Finish up or plug in the charger.")
            NSSound(named: "Sosumi")?.play()
        } else if b.level == 1 {
            say("The mount's battery is getting low (\(volts)).")
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

/// The two attended search patterns (ADR 0022).
enum SearchPattern: String, CaseIterable {
    case spiral, raster
}

/// The minimal, attended motion profile (ADR 0022 §1). With the operator
/// present (hands on the clutches and power — layer 1) and the Celestron
/// firmware limits (layer 2), the layer-3 motion-integrity interlocks are
/// omitted: they were faulting *legitimate* attended motion — the
/// backlash-canceling approach overshoot tripped OppositeMotion on about
/// half of the first-night tile moves. We keep the positional/comms guards
/// that don't impede the work (the altitude envelope, the command/ack/goto
/// deadlines, the goto tolerance), which stay at their defaults.
///
/// - `max_goto_deg` 3°: a raster's jump to its first corner is ~2.3°; gotos
///   self-terminate and the mount is slow, so a few seconds of travel per leg
///   is fine. (Was 1°, which refused the raster.)
/// - `motion_deg_s` 0.3: OppositeMotion/UnexpectedMotion ignore a slow
///   settling or backlash reversal (the −0.134°/s first-night trip); a real
///   runaway at the jog speed (≤1°/s) still faults.
/// - `overspeed_fraction` 2.0: the anti-backlash slack take-up may briefly
///   outrun the commanded rate without faulting.
/// - `min_observed_fraction` 0.1: a reversal leg whose travel is eaten by
///   gear slack is not read as a stall.
/// The attended, operator-present motion profile (ADR 0022 §1). The equipment
/// is slow and can't damage itself at jog speed, and the operator is standing
/// by with hands on the clutches and the power. So the layer-3 interlocks are
/// off (they faulted legitimate motion), and the per-goto distance cap is a
/// full turn — effectively no limit — so a search sweeps as wide as asked in
/// one self-terminating move. Every goto still ends itself at its target.
/// Attended operation (ADR 0022 amendment 4): the operator watches the
/// mount, so missed feedback and the altitude envelope never stop a run.
/// Feedback may lag up to 10 s (hand-controller stalls), the altitude
/// envelope is the whole sky, and what faults remain clear themselves
/// (`MosaicSession.recoverFromFault`).
private var attendedSafety: [String: Any] {
    [
        "min_altitude_deg": -90.0,
        "max_altitude_deg": 90.0,
        "imu_max_age_ms": 10_000,
        "send_deadline_ms": 10_000,
        "ack_deadline_ms": 10_000,
        "max_goto_deg": 360.0,
        "motion_deg_s": 0.3,
        "overspeed_fraction": 2.0,
        "min_observed_fraction": 0.1,
    ]
}

/// Wrap degrees to −180…180 (the app can't see MoonMosaicCore's own copy).
private func wrap180app(_ d: Double) -> Double {
    let x = d.truncatingRemainder(dividingBy: 360)
    if x > 180 { return x - 360 }
    if x < -180 { return x + 360 }
    return x
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
