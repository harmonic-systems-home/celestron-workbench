import AppKit
import Foundation
import MoonMosaicCore
import SwiftUI

/// The simulator window's state (ADR 0022 amendment 7): the things the
/// simulator stands in for (optics, focus knob, scene, sky and air), random
/// scenarios from a seed, and the truth for the wide sky view.
@MainActor
final class SimulatorModel: ObservableObject {
    enum OpticsPreset: String, CaseIterable, Identifiable {
        case sct8 = "8″ SCT, ASI662MC, diagonal"
        case sct8Straight = "8″ SCT, ASI662MC, no diagonal"
        case sct8Barlow = "8″ SCT, ASI662MC, 2× Barlow"
        case sct8Reducer = "8″ SCT, ASI662MC, 0.63× reducer"
        case sct8Wide = "8″ SCT, wide camera"
        var id: String { rawValue }
        var optics: SimOptics {
            var o = SimOptics.sct8
            switch self {
            case .sct8: break
            case .sct8Straight: o.diagonal = false
            case .sct8Barlow: o.multiplier = 2
            case .sct8Reducer: o.multiplier = 0.63
            case .sct8Wide: o.sensor = .wide
            }
            return o
        }
    }

    enum SceneChoice: String, CaseIterable, Identifiable {
        case library = "Scene library"
        case tonight = "Synthetic, tonight's phase"
        case phase = "Synthetic, chosen phase"
        case file = "Image file"
        var id: String { rawValue }
    }

    @Published private(set) var attached = false
    @Published var preset: OpticsPreset = .sct8 { didSet { applyOptics() } }
    @Published var cameraRotationDeg: Double = 0 { didSet { applyOptics() } }
    @Published var sceneChoice: SceneChoice = .tonight { didSet { applyScene() } }
    @Published var phaseAngleDeg: Double = 60
    @Published private(set) var sceneFile: URL?
    @Published private(set) var sceneNote = ""
    /// A folder of scene images (with optional `<image>.json` sidecars),
    /// kept in the private data folder: chosen once, remembered here.
    @Published private(set) var libraryFolder: URL? =
        UserDefaults.standard.string(forKey: "simSceneLibrary").map { URL(fileURLWithPath: $0) }
    @Published private(set) var library: [URL] = []
    /// Each library scene's name for the picker: phase, place, date.
    @Published private(set) var libraryNames: [URL: String] = [:]
    @Published var libraryScene: URL? { didSet { if sceneChoice == .library, oldValue != libraryScene { applyScene() } } }
    @Published private(set) var loadingScene = false
    /// The chosen library scene's time and place, which set the simulated
    /// sky at the next Connect: the ephemeris then matches the image.
    var sceneMoment: (time: Date, site: Site?)? {
        guard let url = libraryScene, let info = MoonScene.Info.sidecar(for: url), let t = info.taken else { return nil }
        let site = info.latitude.flatMap { lat in info.longitude.map { Site(latitudeDeg: lat, longitudeDeg: $0) } }
        return (t, site)
    }
    @Published var seeingArcsec: Double = 2.5 { didSet { applyConditions() } }
    @Published var skyLevel: Double = 0 { didSet { applyConditions() } }
    @Published var transmission: Double = 1 { didSet { applyConditions() } }
    @Published var glowLevel: Double = 0.0001 { didSet { applyConditions() } }
    @Published var shakeArcsec: Double = 20 { didSet { applyConditions() } }
    @Published var seed: UInt64 = 1
    /// Where the Moon starts, from the mount's position at connect (degrees
    /// of azimuth and altitude axis).
    @Published var moonOffsetDeg: (az: Double, alt: Double) = (0.4, 0.25)
    @Published private(set) var focusTurns: Double = 0
    /// The truth, for the wide sky view: the camera's pointing from the
    /// Moon's centre (arcseconds), its path, its frame's corners, and where
    /// the search area sits.
    @Published private(set) var pointing: CGPoint = .zero
    @Published private(set) var trail: [CGPoint] = []
    @Published private(set) var footprint: [CGPoint] = []
    @Published private(set) var searchCentre: CGPoint = .zero
    @Published private(set) var reachArcsec: Double = 7200
    @Published private(set) var moonRadiusArcsec: Double = 930
    @Published private(set) var brightLimbDeg: Double?
    /// The scene's phase angle now, for drawing its terminator.
    @Published private(set) var phaseAngleNowDeg: Double?

    /// The mount's axes and the true Moon's, in the same moment (degrees),
    /// written by the sky provider each frame: the search map draws both
    /// from one reading, so the Moon doesn't jitter against the frame.
    let truth = SimTruth()
    @Published private(set) var mountAxesDeg: [Double]?
    @Published private(set) var moonAxesDeg: [Double]?

    /// Rehearsal speed: the simulated mount's gotos and the settling waits
    /// (simulated mount only; the real mount moves at its own speed).
    @Published var speed: Double = 1 { didSet { onSpeedChanged?(speed) } }
    var onSpeedChanged: ((Double) -> Void)?
    /// Fault injection (rehearsing recovery): mount faults go to the app,
    /// which owns the mount; camera faults are applied here.
    var onMountFault: ((MountSession.SimFault) -> Void)?
    @Published var dropFrames: Double = 0 { didSet { applyConditions() } }
    private var cameraStalledUntil: Date?
    /// The camera stops delivering frames for `seconds`.
    func stallCamera(_ seconds: Double) {
        cameraStalledUntil = Date().addingTimeInterval(seconds)
        applyConditions()
    }

    /// Called when the Moon's starting point changes, to re-aim the sky.
    var onSkyChanged: (() -> Void)?

    private weak var camera: SimCamera?
    private var site = Site(latitudeDeg: 0, longitudeDeg: 0)
    private var clock: @Sendable () -> Date = { Date() }
    private var timer: Timer?

    init() {
        // The library is there before Connect: a scene chosen then sets the
        // simulated sky's moment.
        refreshLibrary()
    }

    /// When the session's clock started (to know a scene's moment is this one).
    private var sessionStart = Date.distantPast

    func attach(_ camera: SimCamera, site: Site, clock: @escaping @Sendable () -> Date, reachDeg: Double) {
        if !attached { sessionStart = clock() }
        let first = !attached || self.camera !== camera
        self.camera = camera
        self.site = site
        self.clock = clock
        attached = true
        moonRadiusArcsec = camera.moonRadiusArcsec
        reachArcsec = reachDeg * 3600
        applyOptics()
        applyConditions()
        if first {
            refreshLibrary()
            // Keep a scene chosen before Connect (it set the clock); else the
            // one nearest tonight's phase.
            if libraryScene == nil, let best = nearestPhase() {
                libraryScene = best
            }
            if libraryScene != nil { sceneChoice = .library }
            applyScene()
            trail = []
            let p = camera.pointing
            searchCentre = CGPoint(x: p.x, y: p.y)
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func detach() {
        timer?.invalidate()
        timer = nil
        camera = nil
        attached = false
    }

    // MARK: - Controls

    func turnFocus(_ turns: Double) {
        camera?.focuser.turn(by: turns)
        focusTurns = camera?.focuser.turns ?? 0
    }

    func chooseSceneFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "A Moon image for the simulated camera"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        sceneFile = url
        sceneChoice = .file
        applyScene()
    }

    func chooseLibraryFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "A folder of Moon images for the simulator"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        libraryFolder = url
        UserDefaults.standard.set(url.path, forKey: "simSceneLibrary")
        refreshLibrary()
        libraryScene = nearestPhase() ?? library.first
        sceneChoice = .library
    }

    private func refreshLibrary() {
        guard let folder = libraryFolder,
            let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        else { library = []; return }
        let kinds = ["jpg", "jpeg", "png", "tif", "tiff", "heic"]
        // The folder and one level of subfolders (own images, downloads…).
        var all = files
        for sub in files where (try? sub.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            all += (try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil)) ?? []
        }
        let images = all.filter { kinds.contains($0.pathExtension.lowercased()) }
        var names: [URL: String] = [:]
        var order: [URL: Double] = [:]
        for url in images {
            let info = MoonScene.Info.sidecar(for: url)
            guard let t = info?.taken else {
                names[url] = url.deletingPathExtension().lastPathComponent
                order[url] = 2
                continue
            }
            // Phase from the moment: the lit fraction, and waxing or waning.
            let f = Ephemeris.phase(at: t, from: site).illuminatedFraction
            let later = Ephemeris.phase(at: t.addingTimeInterval(6 * 3600), from: site).illuminatedFraction
            let waxing = later > f
            let kind: String
            switch f {
            case ..<0.03: kind = "New"
            case ..<0.40: kind = waxing ? "Waxing crescent" : "Waning crescent"
            case ..<0.60: kind = waxing ? "First quarter" : "Last quarter"
            case ..<0.97: kind = waxing ? "Waxing gibbous" : "Waning gibbous"
            default: kind = "Full"
            }
            let place = info?.place ?? "unknown place"
            names[url] = String(format: "%@ %.0f%% · %@ · %@", kind, f * 100, place, t.formatted(date: .abbreviated, time: .omitted))
            // Sorted through the month: waxing 0→1, then waning 1→2.
            order[url] = waxing ? f : 2 - f
        }
        // Two images of one moment: tell them apart by file name.
        let counts = Dictionary(grouping: names.values, by: { $0 }).mapValues(\.count)
        for (url, name) in names where (counts[name] ?? 0) > 1 {
            names[url] = name + " · " + url.deletingPathExtension().lastPathComponent
        }
        libraryNames = names
        library = images.sorted { (order[$0] ?? 3, names[$0] ?? "") < (order[$1] ?? 3, names[$1] ?? "") }
    }

    /// The library image whose phase (from its sidecar's time) is nearest
    /// tonight's.
    private func nearestPhase() -> URL? {
        let tonight = Ephemeris.phase(at: clock(), from: site).illuminatedFraction
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        func fraction(_ url: URL) -> Double? {
            guard let data = try? Data(contentsOf: url.appendingPathExtension("json")),
                let info = try? d.decode(MoonScene.Info.self, from: data), let t = info.taken
            else { return nil }
            return Ephemeris.phase(at: t, from: site).illuminatedFraction
        }
        return library.compactMap { u in fraction(u).map { (u, abs($0 - tonight)) } }
            .min { $0.1 < $1.1 }?.0
    }

    func applyPhase() {
        if sceneChoice == .phase { applyScene() }
    }

    /// A random scenario from a new seed: the camera's turn and mirroring,
    /// where the Moon starts (in the search area, out of view), the best
    /// focus, and the seeing. The seed is shown, so a run can be repeated.
    func randomize(reachDeg: Double) {
        seed = UInt64.random(in: 1...999_999)
        applySeed(reachDeg: reachDeg)
    }

    /// Applies the scenario for the current seed.
    func applySeed(reachDeg: Double) {
        var g = SeededGenerator(seed)
        cameraRotationDeg = Double.random(in: 0..<360, using: &g)
        let straight = Bool.random(using: &g)
        preset = straight ? .sct8Straight : .sct8
        // Out of view: at least the Moon's radius plus half the field's
        // diagonal from the start, within the search area.
        let field = preset.optics.fieldArcmin
        let clear = (moonRadiusArcsec + 30 * hypot(field.width, field.height)) / 3600
        var az = 0.0, alt = 0.0
        repeat {
            az = Double.random(in: -reachDeg...reachDeg, using: &g)
            alt = Double.random(in: (-0.6 * reachDeg)...(0.6 * reachDeg), using: &g)
        } while hypot(az, alt) < clear
        moonOffsetDeg = (az, alt)
        let best = Double.random(in: -1.5...1.5, using: &g)
        camera?.focuser = SimFocuser(bestTurns: best, startTurns: 0)
        focusTurns = 0
        seeingArcsec = Double.random(in: 1.5...4, using: &g)
        trail = []
        onSkyChanged?()
    }

    // MARK: - Applying

    private func applyOptics() {
        var o = preset.optics
        o.cameraRotationDeg = cameraRotationDeg
        camera?.optics = o
    }

    private func applyConditions() {
        var c = SimCamera.Conditions()
        c.seeingArcsec = seeingArcsec
        c.skyLevel = skyLevel
        c.transmission = transmission
        c.glowLevel = glowLevel
        c.shakeArcsec = shakeArcsec
        c.dropFrames = dropFrames
        c.stalledUntil = cameraStalledUntil
        camera?.conditions = c
    }

    private func applyScene() {
        guard let camera else { return }
        let now = clock()
        let phase = Ephemeris.phase(at: now, from: site)
        switch sceneChoice {
        case .tonight:
            camera.scene = MoonScene.synthetic(size: 1024, phaseAngleDeg: phase.phaseAngleDeg, brightLimbDeg: 0)
            sceneNote = String(format: "Synthetic, %.0f%% lit (tonight)", phase.illuminatedFraction * 100)
        case .phase:
            camera.scene = MoonScene.synthetic(size: 1024, phaseAngleDeg: phaseAngleDeg, brightLimbDeg: 0)
            sceneNote = String(format: "Synthetic, %.0f%% lit", (1 + cos(phaseAngleDeg * .pi / 180)) * 50)
        case .file, .library:
            guard let url = sceneChoice == .file ? sceneFile : libraryScene else {
                sceneNote = sceneChoice == .file ? "Choose an image file." : "Choose a scene folder."
                return
            }
            // Large images take a few seconds: load off the main thread.
            loadingScene = true
            sceneNote = "Loading \(url.lastPathComponent)…"
            let limb = phase.brightLimbFromZenithDeg
            Task.detached { [weak self, weak camera] in
                let result = Result { try MoonScene(contentsOf: url) }
                await MainActor.run {
                    guard let self else { return }
                    self.loadingScene = false
                    switch result {
                    case .success(let scene):
                        camera?.scene = scene
                        // A level frame at the session's own moment is the sky
                        // as it was: no turn. Otherwise turn it so its bright
                        // limb points where the ephemeris says.
                        let sameMoment = scene.info.taken.map { abs($0.timeIntervalSince(self.sessionStart)) < 600 } ?? false
                        if scene.info.level == true, sameMoment {
                            camera?.sceneRotationDeg = 0
                        } else {
                            camera?.alignBrightLimb(toDeg: limb)
                        }
                        self.brightLimbDeg = limb
                        self.phaseAngleNowDeg = phase.phaseAngleDeg
                        let across = scene.radius > 0 ? (camera?.moonRadiusArcsec ?? 930) / scene.radius : 0
                        self.sceneNote = String(
                            format: "%@: %d×%d, %.2f″ per image pixel, %.0f%% lit%@", scene.name, scene.width,
                            scene.height, across, scene.litFraction * 100,
                            scene.brightLimbDeg == nil ? " (no bright limb: not turned)" : "")
                    case .failure(let error):
                        self.sceneNote = "\(error)"
                    }
                }
            }
            return
        }
        // The scene's bright limb where the ephemeris puts it now.
        camera.alignBrightLimb(toDeg: phase.brightLimbFromZenithDeg)
        brightLimbDeg = phase.brightLimbFromZenithDeg
        phaseAngleNowDeg = sceneChoice == .phase ? phaseAngleDeg : phase.phaseAngleDeg
    }

    private func tick() {
        guard let camera else { return }
        if let t = truth.latest {
            mountAxesDeg = t.mount
            moonAxesDeg = t.moon
        }
        let p = camera.pointing
        guard abs(p.x) < 1e5, abs(p.y) < 1e5 else { return }
        let point = CGPoint(x: p.x, y: p.y)
        pointing = point
        if let last = trail.last, hypot(last.x - point.x, last.y - point.y) < 5 {
        } else {
            trail.append(point)
            if trail.count > 4000 { trail.removeFirst(trail.count - 4000) }
        }
        let info = camera.info
        let (hw, hh) = (Double(info.width) / 2, Double(info.height) / 2)
        footprint = [(-hw, -hh), (hw, -hh), (hw, hh), (-hw, hh)].map { u, v in
            let s = camera.sky(u: u, v: v, pointing: p)
            return CGPoint(x: s.x, y: s.y)
        }
    }
}

/// A seeded generator for repeatable scenarios.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The simulated sky's latest truth, shared with the camera's thread.
final class SimTruth: @unchecked Sendable {
    private let lock = NSLock()
    private var value: (mount: [Double], moon: [Double])?
    var latest: (mount: [Double], moon: [Double])? { lock.withLock { value } }
    func set(mount: [Double], moon: [Double]) { lock.withLock { value = (mount, moon) } }
}
