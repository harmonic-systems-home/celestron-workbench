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
        _ scenario: Scenario, site: Site = Site(latitudeDeg: 40, longitudeDeg: -100), speed: Double = 5,
        tiles: Int = 2, folder: URL? = nil, log: @escaping @Sendable (String) -> Void = { _ in }
    ) async -> Result {
        var steps: [Step] = []
        do {
            // The first time the Moon is well up, then the scenario's hours on.
            var t = Date(timeIntervalSince1970: 1_793_491_200)
            for _ in 0..<(24 * 30) {
                if Ephemeris.moon(at: t, from: site).horizontal.altDeg > 40 { break }
                t.addTimeInterval(3600)
            }
            let epoch = t.addingTimeInterval(scenario.hoursLater * 3600)
            let started = Date()
            let clock: @Sendable () -> Date = { epoch.addingTimeInterval(Date().timeIntervalSince(started)) }
            let mount = try MountSession(port: "simulate", safety: ["max_goto_deg": 10.0])
            try mount.setSimSpeed(speed)
            var optics = SimOptics(focalLengthMm: 2032, sensor: .testMono)
            optics.diagonal = scenario.diagonal
            optics.cameraRotationDeg = scenario.cameraRotationDeg
            let truthOptics = optics
            let phase = Ephemeris.phase(at: clock(), from: site)
            let camera = SimCamera(
                optics: optics, scene: MoonScene.synthetic(size: 768, phaseAngleDeg: phase.phaseAngleDeg),
                seed: scenario.seed)
            camera.alignBrightLimb(toDeg: phase.brightLimbFromZenithDeg)
            var c = SimCamera.Conditions()
            c.seeingArcsec = scenario.seeingArcsec
            camera.conditions = c
            camera.moonRadiusArcsec = Ephemeris.moon(at: clock(), from: site).diameterDeg * 1800
            var settings = MosaicSettings(site: site)
            settings.focalLengthMm = 2032
            settings.settleSeconds = 0.7 / speed
            settings.videoSeconds = 1
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
                    let o = try await session.searchSweep(
                        halfWidthDeg: 2, halfHeightDeg: 1.2, converge: MosaicSession.Converge(),
                        found: { Blob.looksLikeMoon($0) })
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
                await step("Orient Moon", {
                    let fit = try await session.findCentre()
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
