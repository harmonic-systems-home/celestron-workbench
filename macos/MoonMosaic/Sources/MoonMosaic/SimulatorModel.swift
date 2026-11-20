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
    @Published var seeingArcsec: Double = 2.5 { didSet { applyConditions() } }
    @Published var skyLevel: Double = 0 { didSet { applyConditions() } }
    @Published var transmission: Double = 1 { didSet { applyConditions() } }
    @Published var glowLevel: Double = 0.02 { didSet { applyConditions() } }
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

    /// Called when the Moon's starting point changes, to re-aim the sky.
    var onSkyChanged: (() -> Void)?

    private weak var camera: SimCamera?
    private var site = Site(latitudeDeg: 0, longitudeDeg: 0)
    private var clock: @Sendable () -> Date = { Date() }
    private var timer: Timer?

    func attach(_ camera: SimCamera, site: Site, clock: @escaping @Sendable () -> Date, reachDeg: Double) {
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
        case .file:
            guard let url = sceneFile else {
                sceneNote = "Choose an image file."
                return
            }
            do {
                let scene = try MoonScene(contentsOf: url)
                camera.scene = scene
                sceneNote = String(
                    format: "%@: %d×%d, disk %.0f px across, %.0f%% lit%@", scene.name, scene.width,
                    scene.height, 2 * scene.radius, scene.litFraction * 100,
                    scene.brightLimbDeg == nil ? " (no bright limb: not turned)" : "")
            } catch {
                sceneNote = "\(error)"
                return
            }
        }
        // The scene's bright limb where the ephemeris puts it tonight.
        camera.alignBrightLimb(toDeg: phase.brightLimbFromZenithDeg)
        brightLimbDeg = phase.brightLimbFromZenithDeg
    }

    private func tick() {
        guard let camera else { return }
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
