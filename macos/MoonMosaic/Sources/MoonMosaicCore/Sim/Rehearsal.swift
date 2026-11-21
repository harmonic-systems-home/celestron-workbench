import Foundation

/// A seeded generator for repeatable scenarios.
public struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    public init(_ seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The test runner (ADR 0022 amendment 7): the flow played through on the
/// simulated mount and camera for scenarios drawn from seeds, with each
/// step's result and time recorded, so a change can be judged on many
/// scenarios at once rather than one rehearsal by hand.
public enum Rehearsal {
    /// The major phases, for test sets: each picks a moment when the Moon
    /// is at that phase and well up at the test site.
    public enum Phase: String, Sendable, Codable, CaseIterable {
        case waxingCrescent = "waxing crescent"
        case firstQuarter = "first quarter"
        case waxingGibbous = "waxing gibbous"
        case full
        case waningGibbous = "waning gibbous"
        case lastQuarter = "last quarter"
        case waningCrescent = "waning crescent"

        /// The phase angle (0 full, 180 new) and whether it is waxing.
        public var angleDeg: Double {
            switch self {
            case .waxingCrescent, .waningCrescent: 125
            case .firstQuarter, .lastQuarter: 90
            case .waxingGibbous, .waningGibbous: 45
            case .full: 4
            }
        }
        public var waxing: Bool? {
            switch self {
            case .waxingCrescent, .firstQuarter, .waxingGibbous: true
            case .full: nil
            default: false
            }
        }
    }

    /// The cameras the operator has.
    public enum CameraModel: String, Sendable, Codable, CaseIterable {
        case asi662mc = "662"
        case asi482mc = "482"
        public var sensor: SimSensor { self == .asi662mc ? .asi662mc : .asi482mc }
    }

    /// The first moment from 2026-11-01 when the Moon is at `phase` (within
    /// 8°, full within 10°) and at least 30° up, at night if it can be.
    public static func moment(for phase: Phase, site: Site, daytime: Bool = false) -> Date? {
        let start = Date(timeIntervalSince1970: 1_793_491_200)
        for night in daytime ? [false] : [true, false] {
            var t = start
            for _ in 0..<(24 * 4 * 70) {
                defer { t.addTimeInterval(900) }
                let p = Ephemeris.phase(at: t, from: site)
                let tolerance = phase == .full ? 10.0 : 8.0
                guard abs(p.phaseAngleDeg - phase.angleDeg) < tolerance || (phase == .full && p.phaseAngleDeg < tolerance)
                else { continue }
                if let waxing = phase.waxing {
                    let later = Ephemeris.phase(at: t.addingTimeInterval(6 * 3600), from: site)
                    guard (later.illuminatedFraction > p.illuminatedFraction) == waxing else { continue }
                }
                guard Ephemeris.moon(at: t, from: site).horizontal.altDeg > 30 else { continue }
                let sunAlt = Ephemeris.horizontal(Ephemeris.sun(at: t), at: t, from: site).altDeg
                if night, sunAlt > -6 { continue }
                if daytime, sunAlt < 10 { continue }
                return t
            }
        }
        return nil
    }

    /// What a seed sets: the camera's turn and mirroring, where the Moon is
    /// against the start, the seeing, the hidden best focus, the phase.
    public struct Scenario: Sendable, Codable, Equatable {
        public let seed: UInt64
        public var cameraRotationDeg: Double
        public var diagonal: Bool
        /// The Moon against the scope's start (degrees on the axes).
        public var moonOffsetAz: Double
        public var moonOffsetAlt: Double
        public var seeingArcsec: Double
        public var phaseAngleDeg: Double
        /// Hours after the first time the Moon is high at the test site.
        public var hoursLater: Double
        /// A test set's choices, overriding the seed's: the phase (the
        /// moment comes from it), the camera, its turn and the diagonal.
        public var phase: Phase?
        public var camera: CameraModel = .asi662mc
        /// By day: the Sun well up, a bright blue sky.
        public var daytime = false
        /// A scene image (with its sidecar): its moment and place set the
        /// sky, its own sky the brightness and colour; nil for synthetic.
        public var scenePath: String?
        /// The camera's exposure and gain (the app's defaults otherwise).
        public var exposureUs: Int?
        public var gain: Int?

        /// A test set's scenario: the seed sets the rest (where the Moon is,
        /// the seeing).
        public init(seed: UInt64, phase: Phase?, camera: CameraModel, rotationDeg: Double, diagonal: Bool) {
            self.init(seed: seed)
            self.phase = phase
            self.camera = camera
            self.cameraRotationDeg = rotationDeg
            self.diagonal = diagonal
        }

        public init(seed: UInt64, reachDeg: Double = 1.5) {
            var g = SeededGenerator(seed)
            self.seed = seed
            cameraRotationDeg = Double.random(in: 0..<360, using: &g)
            diagonal = Bool.random(using: &g)
            let clear = 0.45
            var az = 0.0, alt = 0.0
            repeat {
                az = Double.random(in: -reachDeg...reachDeg, using: &g)
                alt = Double.random(in: (-0.6 * reachDeg)...(0.6 * reachDeg), using: &g)
            } while hypot(az, alt) < clear
            (moonOffsetAz, moonOffsetAlt) = (az, alt)
            seeingArcsec = Double.random(in: 1.5...4, using: &g)
            phaseAngleDeg = Double.random(in: 20...140, using: &g)
            hoursLater = Double.random(in: 0...2, using: &g)
        }
    }

    public struct Step: Sendable, Codable {
        public let name: String
        public let ok: Bool
        public let seconds: Double
        public let note: String?
    }

    public struct Result: Sendable, Codable {
        public let scenario: Scenario
        public let steps: [Step]
        public var ok: Bool { steps.allSatisfy(\.ok) }
        public var seconds: Double { steps.map(\.seconds).reduce(0, +) }
    }

    /// The steps run, in order: Find (sweep), Here, Orient Camera, Orient
    /// Moon, Plan, and the first `tiles` sunlit tiles captured.
    public static func run(
        _ scenario: Scenario, site siteIn: Site = Site(latitudeDeg: 40, longitudeDeg: -100), speed: Double = 5,
        tiles: Int = 2, folder: URL? = nil, log: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Result {
        var loaded: MoonScene?
        if let path = scenario.scenePath {
            do {
                loaded = try MoonScene(contentsOf: URL(fileURLWithPath: path))
            } catch {
                return Result(scenario: scenario, steps: [Step(name: "Setup", ok: false, seconds: 0, note: "\(error)")])
            }
        }
        let site: Site = {
            if let i = loaded?.info, let lat = i.latitude, let lon = i.longitude { return Site(latitudeDeg: lat, longitudeDeg: lon) }
            return siteIn
        }()
        var steps: [Step] = []
        do {
            // The test set's phase; else the first time the Moon is well up,
            // then the scenario's hours on.
            let epoch: Date
            if let taken = loaded?.info.taken {
                epoch = taken
            } else if let phase = scenario.phase {
                guard let m = moment(for: phase, site: site, daytime: scenario.daytime) else {
                    throw MosaicError(description: "no moment found for the \(phase.rawValue) Moon")
                }
                epoch = m
            } else {
                var t = Date(timeIntervalSince1970: 1_793_491_200)
                for _ in 0..<(24 * 30) {
                    if Ephemeris.moon(at: t, from: site).horizontal.altDeg > 40 { break }
                    t.addTimeInterval(3600)
                }
                epoch = t.addingTimeInterval(scenario.hoursLater * 3600)
            }
            let started = Date()
            let clock: @Sendable () -> Date = { epoch.addingTimeInterval(Date().timeIntervalSince(started)) }
            let mount = try MountSession(port: "simulate", safety: ["max_goto_deg": 10.0])
            try mount.setSimSpeed(speed)
            var optics = SimOptics(focalLengthMm: 2032, sensor: scenario.camera.sensor)
            optics.diagonal = scenario.diagonal
            optics.cameraRotationDeg = scenario.cameraRotationDeg
            let truthOptics = optics
            let phase = Ephemeris.phase(at: clock(), from: site)
            let camera = SimCamera(
                optics: optics, scene: loaded ?? MoonScene.synthetic(size: 768, phaseAngleDeg: phase.phaseAngleDeg),
                seed: scenario.seed)
            if loaded?.info.level == true {
                camera.sceneRotationDeg = 0
            } else if camera.alignNorth(toDeg: Ephemeris.moonNorthFromZenithDeg(at: clock(), from: site)) == false {
                camera.alignBrightLimb(toDeg: phase.brightLimbFromZenithDeg)
            }
            var c = SimCamera.Conditions()
            c.seeingArcsec = scenario.seeingArcsec
            if scenario.daytime {
                c.skyLevel = 0.25
                c.skyColour = [0.55, 1, 1.6]
            }
            if let s = loaded, s.skyLevel > 0.01 {
                c.skyLevel = min(0.5, s.skyLevel)
                c.skyColour = s.skyColour ?? [0.55, 1, 1.6]
            }
            camera.conditions = c
            camera.moonRadiusArcsec = Ephemeris.moon(at: clock(), from: site).diameterDeg * 1800
            var settings = MosaicSettings(site: site)
            settings.focalLengthMm = 2032
            settings.settleSeconds = 0.7 / speed
            settings.videoSeconds = 1
            if let e = scenario.exposureUs { settings.exposureUs = e }
            if let g = scenario.gain { settings.gain = g }
            let session = MosaicSession(
                mount: mount, camera: camera, settings: settings, clock: clock,
                onEvent: { if case .message(let m) = $0 { log(m) } })
            session.diagnostics = folder
            for _ in 0..<100 where try mount.status().positionsDeg == nil {
                try await Task.sleep(for: .milliseconds(50))
            }
            try mount.setAltitudeReference(Ephemeris.moon(at: clock(), from: site).horizontal.altDeg)
            let p0 = try await session.freshPosition()
            let o0 = session.offset(of: p0, at: clock())
            let (dAz, dAlt) = (scenario.moonOffsetAz, scenario.moonOffsetAlt)
            camera.provider = { [weak session] in
                guard let session, let st = try? session.mount.status(), var p = st.positionsDeg else { return (1e6, 1e6) }
                if let r = st.tracking, let age = st.positionsAgeMs {
                    p = [p[0] + r[0] * Double(age) / 1000, p[1] + r[1] * Double(age) / 1000]
                }
                let o = session.offset(of: p, at: clock())
                let alt = Ephemeris.moon(at: clock(), from: site).horizontal.altDeg
                return (
                    (wrap180(o.az - o0.az) - dAz) * cos(alt * .pi / 180) * 3600, (o.alt - o0.alt - dAlt) * 3600
                )
            }
            defer { try? mount.stopTracking() }

            func step(_ name: String, limit: Double = 180, _ body: @escaping @Sendable () async throws -> String?) async -> Bool {
                let t0 = Date()
                do {
                    // A step that hangs fails at its limit (and is cancelled).
                    let note = try await withThrowingTaskGroup(of: String?.self) { g in
                        g.addTask { try await body() }
                        g.addTask {
                            try await Task.sleep(for: .seconds(limit))
                            throw MosaicError(description: "timed out after \(Int(limit)) s")
                        }
                        defer { g.cancelAll() }
                        return try await g.next() ?? nil
                    }
                    steps.append(Step(name: name, ok: true, seconds: Date().timeIntervalSince(t0), note: note))
                    return true
                } catch {
                    steps.append(Step(name: name, ok: false, seconds: Date().timeIntervalSince(t0), note: "\(error)"))
                    return false
                }
            }
            guard
                await step("Find", {
                    let sky: Blob.Sky = scenario.daytime ? .day : .clearNight
                    let o = try await session.searchSweep(
                        halfWidthDeg: 2, halfHeightDeg: 1.2, converge: MosaicSession.Converge(),
                        found: { Blob.looksLikeMoon($0, sky: sky) })
                    guard o.found, o.converged else { throw MosaicError(description: "not found (\(o.stops) rows)") }
                    let p = camera.pointing
                    return String(format: "%d rows; ended %.0f″ from the centre", o.stops, hypot(p.x, p.y))
                })
            else { return Result(scenario: scenario, steps: steps) }
            guard await step("Here", { try await session.markHere(); return nil }) else {
                return Result(scenario: scenario, steps: steps)
            }
            guard
                await step("Orient Camera", {
                    let o = try await session.orientCamera()
                    let truth = truthOptics.arcsecPerPixel
                    let m = o.calibration
                    guard m.mirrored == truthOptics.diagonal else {
                        throw MosaicError(description: "mirroring wrong (found \(m.mirrored), truth \(truthOptics.diagonal))")
                    }
                    guard abs(m.arcsecPerPixel / truth - 1) < 0.03 else {
                        throw MosaicError(description: String(format: "scale %.4f against %.4f", m.arcsecPerPixel, truth))
                    }
                    return String(format: "%.4f″/px (truth %.4f), turned %.1f°", m.arcsecPerPixel, truth, m.rotationDeg)
                })
            else { return Result(scenario: scenario, steps: steps) }
            guard
                await step("Orient Moon", limit: 400, {
                    let fit = try await session.findCentre()
                    if let off = session.checkRotation(), off > 30 {
                        throw MosaicError(description: String(format: "rotation check %.0f° off", off))
                    }
                    let p = camera.pointing
                    guard hypot(p.x, p.y) < 120 else {
                        throw MosaicError(description: String(format: "centred %.0f″ off", hypot(p.x, p.y)))
                    }
                    return String(format: "centred %.0f″ off; fit moved %.0f″", hypot(p.x, p.y), hypot(fit.centre.x, fit.centre.y))
                })
            else { return Result(scenario: scenario, steps: steps) }
            guard
                await step("Plan", {
                    let plan = try session.makePlan()
                    return "\(plan.tiles.count) tiles, \(plan.tiles.filter(\.lit).count) sunlit"
                })
            else { return Result(scenario: scenario, steps: steps) }
            if tiles > 0, let plan = session.plan {
                let dir = folder ?? FileManager.default.temporaryDirectory.appendingPathComponent("rehearsal-\(scenario.seed)")
                _ = await step("Capture \(tiles)", {
                    let ids = Array(plan.tiles.filter(\.lit).map(\.id).prefix(tiles))
                    try await session.run(tiles: ids, into: dir)
                    let done = ids.filter { if case .done = session.states[$0] { true } else { false } }.count
                    guard done == ids.count else { throw MosaicError(description: "\(done) of \(ids.count) done") }
                    return "\(done) tiles"
                })
                if folder == nil { try? FileManager.default.removeItem(at: dir) }
            }
        } catch {
            steps.append(Step(name: "Setup", ok: false, seconds: 0, note: "\(error)"))
        }
        return Result(scenario: scenario, steps: steps)
    }
}
