import MoonMosaicCore
import SwiftUI

/// The simulator's own window (ADR 0022 amendment 7): controls for what the
/// simulator stands in for, and a wide view of the sky with the true Moon and
/// the camera's footprint and path. The app's buttons are tested against it.
struct SimulatorView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sim: SimulatorModel

    var body: some View {
        HStack(spacing: 0) {
            controls
                .frame(width: 340)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Sky around the Moon (the truth)").font(.headline)
                SkyMap(sim: sim)
                    .background(Color.black)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                Text(
                    "The sky as seen by eye: x along azimuth, y up. The rectangle is the search area, the box the camera's frame (its top edge orange), the line its path. With a star diagonal the camera's image is mirrored left to right against this view, as through the eyepiece."
                )
                .font(.caption).foregroundStyle(.secondary)
                viewerControls
            }
            .padding(10)
        }
    }

    /// Under the sky view: the camera's turn in the focuser, the diagonal,
    /// where the Moon sits in the search area, and dice for each.
    private var viewerControls: some View {
        let reach = model.searchReachDeg
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Slider(value: $sim.cameraRotationDeg, in: 0...359, step: 1) {
                    Text("Camera turned \(Int(sim.cameraRotationDeg))°").frame(width: 150, alignment: .leading)
                }
                Toggle(
                    "Diagonal",
                    isOn: Binding(
                        get: { sim.preset.optics.diagonal },
                        set: { sim.preset = sim.preset.withDiagonal($0) }))
                Button("Random turn") { sim.randomizeRotation() }
            }
            HStack {
                Slider(
                    value: Binding(get: { moonAz ?? sim.moonOffsetDeg.az }, set: { moonAz = $0 }),
                    in: -reach...reach, step: 0.05
                ) {
                    Text(String(format: "Moon %+.2f° az", moonAz ?? sim.moonOffsetDeg.az)).frame(width: 150, alignment: .leading)
                } onEditingChanged: { editing in if !editing { placeMoon() } }
                Slider(
                    value: Binding(get: { moonAlt ?? sim.moonOffsetDeg.alt }, set: { moonAlt = $0 }),
                    in: (-0.6 * reach)...(0.6 * reach), step: 0.05
                ) {
                    Text(String(format: "%+.2f° alt", moonAlt ?? sim.moonOffsetDeg.alt)).frame(width: 70, alignment: .leading)
                } onEditingChanged: { editing in if !editing { placeMoon() } }
                Button("Random place") { sim.randomizePlace(reachDeg: reach) }
            }
            HStack {
                Text("From where the scope started, inside the search area (±\(String(format: "%.2g", reach))°).")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Randomize all") { sim.randomize(reachDeg: reach) }
            }
        }
    }

    /// The Moon's place while a slider is being dragged (applied on release).
    @State private var moonAz: Double?
    @State private var moonAlt: Double?
    private func placeMoon() {
        sim.placeMoon(az: moonAz ?? sim.moonOffsetDeg.az, alt: moonAlt ?? sim.moonOffsetDeg.alt)
        moonAz = nil
        moonAlt = nil
    }

    private var controls: some View {
        Form {
            if !sim.attached {
                Text(
                    "Connect with “Rehearse with the simulated mount and camera” or “Simulated camera with the real mount” (Settings) to use these."
                )
                .foregroundStyle(.secondary)
            }
            Section("Scenario") {
                HStack {
                    Text("Seed \(sim.seed)").font(.system(.body, design: .monospaced))
                    Spacer()
                    Button("Random") { sim.randomize(reachDeg: model.searchReachDeg) }
                    Button("Repeat") { sim.applySeed(reachDeg: model.searchReachDeg) }
                }
                Text(
                    String(
                        format: "Moon starts %.2f° az, %.2f° alt from the mount", sim.moonOffsetDeg.az,
                        sim.moonOffsetDeg.alt)
                ).font(.caption)
            }
            Section("Speed") {
                Slider(value: $sim.speed, in: 1...10, step: 1) {
                    Text("Moves \(Int(sim.speed))× faster")
                }
                .disabled(!model.simulate)
                Text(
                    model.simulate
                        ? "The simulated mount's gotos and the settling waits. The Moon still moves at its real rate."
                        : "Only with the simulated mount: the real mount moves at its own speed."
                ).font(.caption).foregroundStyle(.secondary)
            }
            Section("Optics") {
                Picker("Setup", selection: $sim.preset) {
                    ForEach(SimulatorModel.OpticsPreset.allCases) { Text($0.rawValue).tag($0) }
                }
                Slider(value: $sim.cameraRotationDeg, in: 0...359, step: 1) {
                    Text("Camera turned \(Int(sim.cameraRotationDeg))°")
                }
                let o = sim.preset.optics
                Text(
                    String(
                        format: "%.3f″/px, field %.1f′ × %.1f′", o.arcsecPerPixel, o.fieldArcmin.width,
                        o.fieldArcmin.height)
                ).font(.caption)
            }
            Section("Focus knob") {
                HStack {
                    Button("◀◀") { sim.turnFocus(-0.25) }
                    Button("◀") { sim.turnFocus(-0.02) }
                    Text(String(format: "%+.2f turns", sim.focusTurns))
                        .font(.system(.body, design: .monospaced))
                        .frame(minWidth: 90)
                    Button("▶") { sim.turnFocus(0.02) }
                    Button("▶▶") { sim.turnFocus(0.25) }
                }
                Text("Coarse ¼ turn, fine 1/50. Best focus is hidden; reversing shows mirror flop.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Scene") {
                Picker("Scene", selection: $sim.sceneChoice) {
                    ForEach(SimulatorModel.SceneChoice.allCases) { Text($0.rawValue).tag($0) }
                }
                if sim.sceneChoice == .phase {
                    Slider(value: $sim.phaseAngleDeg, in: 0...170, step: 5) {
                        Text("Phase angle \(Int(sim.phaseAngleDeg))°")
                    } onEditingChanged: { editing in
                        if !editing { sim.applyPhase() }
                    }
                }
                if sim.sceneChoice == .library {
                    Picker("Image", selection: $sim.libraryScene) {
                        ForEach(sim.library, id: \.self) { Text(sim.libraryNames[$0] ?? $0.lastPathComponent).tag(Optional($0)) }
                    }
                }
                HStack {
                    Button("Scene folder…") { sim.chooseLibraryFolder() }
                    Button("One image…") { sim.chooseSceneFile() }
                    if sim.loadingScene { ProgressView().controlSize(.small) }
                }
                Text(sim.sceneNote).font(.caption)
            }
            Section("Sky and air") {
                Slider(value: $sim.seeingArcsec, in: 0.5...6, step: 0.25) {
                    Text(String(format: "Seeing %.2f″", sim.seeingArcsec))
                }
                Slider(value: $sim.skyLevel, in: 0...0.5, step: 0.02) {
                    Text(String(format: "Sky %.2f (0 night)", sim.skyLevel))
                }
                Slider(value: $sim.transmission, in: 0.05...1, step: 0.05) {
                    Text(String(format: "Cloud: %.0f%% through", sim.transmission * 100))
                }
                Slider(value: $sim.glowLevel, in: 0...0.005, step: 0.0001) {
                    Text(String(format: "Glow %.4f (haze raises it)", sim.glowLevel))
                }
                Slider(value: $sim.shakeArcsec, in: 0...60, step: 5) {
                    Text(String(format: "Shake after moves %.0f″", sim.shakeArcsec))
                }
                Slider(value: $sim.shimmerArcsec, in: 0...3, step: 0.1) {
                    Text(String(format: "Shimmer %.1f″ (parts of the image wobbling)", sim.shimmerArcsec))
                }
            }
            Section("Faults (rehearse recovery)") {
                HStack {
                    Button("Runaway az") { sim.onMountFault?(.runaway(.azimuth, degS: 0.5, seconds: 4)) }
                    Button("Runaway alt") { sim.onMountFault?(.runaway(.altitude, degS: 0.5, seconds: 4)) }
                }
                HStack {
                    Button("Stall mount") { sim.onMountFault?(.stall(true)) }
                    Button("Overshoot 0.1°") { sim.onMountFault?(.overshoot(0.1)) }
                    Button("Short 0.05°") { sim.onMountFault?(.short(0.05)) }
                }
                HStack {
                    Button("Camera stall 5 s") { sim.stallCamera(5) }
                    Button("Clear mount faults") { sim.onMountFault?(.clear) }
                }
                Slider(value: $sim.dropFrames, in: 0...0.5, step: 0.05) {
                    Text(String(format: "Dropped frames %.0f%%", sim.dropFrames * 100))
                }
                Text("Runaway: as if a hand-controller key stuck (0.5°/s for 4 s). Mount faults need the simulated mount.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

/// The wide sky view: the search area, the Moon (lit side marked), and the
/// camera's frame and path, all in arcseconds from the Moon's centre.
struct SkyMap: View {
    @ObservedObject var sim: SimulatorModel

    var body: some View {
        Canvas { ctx, size in
            // Zoom to fit: the search area as it really runs, the Moon, the
            // camera's frame and its path, with a margin.
            let r0 = sim.moonRadiusArcsec
            let centre = sim.searchCentre
            let box: CGRect = {
                if let b = sim.searchBox { return b.offsetBy(dx: centre.x, dy: centre.y) }
                let reach = sim.reachArcsec
                return CGRect(x: centre.x - reach, y: centre.y - 0.6 * reach, width: 2 * reach, height: 1.2 * reach)
            }()
            var pts: [CGPoint] = [
                CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY),
                CGPoint(x: -r0, y: -r0), CGPoint(x: r0, y: r0),
            ]
            pts += sim.footprint
            pts += sim.trail
            let pad = 0.06 * max(box.width, box.height, 2 * r0)
            let minX = (pts.map(\.x).min() ?? 0) - pad, maxX = (pts.map(\.x).max() ?? 0) + pad
            let minY = (pts.map(\.y).min() ?? 0) - pad, maxY = (pts.map(\.y).max() ?? 0) + pad
            let k = min(size.width / (maxX - minX), size.height / (maxY - minY))
            let ox = size.width / 2 - k * (minX + maxX) / 2
            let oy = size.height / 2 + k * (minY + maxY) / 2
            func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: ox + k * p.x, y: oy - k * p.y) }

            // Search area (the stops' extent).
            let corner = pt(CGPoint(x: box.minX, y: box.maxY))
            let area = CGRect(x: corner.x, y: corner.y, width: box.width * k, height: box.height * k)
            ctx.stroke(Path(area), with: .color(.gray), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            ctx.draw(
                Text(sim.searchBox == nil ? "search area (planned)" : "search area").font(.caption2).foregroundColor(.gray),
                at: CGPoint(x: area.minX + 4, y: area.maxY - 3), anchor: .bottomLeading)
            // A scale bar: a round number of degrees about a fifth of the view.
            let want = (maxX - minX) / 5 / 3600
            let deg = [0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10].last { $0 <= want } ?? 0.05
            let bar = deg * 3600 * k
            let y0 = size.height - 12
            var scale = Path()
            scale.move(to: CGPoint(x: size.width - 12 - bar, y: y0))
            scale.addLine(to: CGPoint(x: size.width - 12, y: y0))
            scale.move(to: CGPoint(x: size.width - 12 - bar, y: y0 - 4))
            scale.addLine(to: CGPoint(x: size.width - 12 - bar, y: y0 + 4))
            scale.move(to: CGPoint(x: size.width - 12, y: y0 - 4))
            scale.addLine(to: CGPoint(x: size.width - 12, y: y0 + 4))
            ctx.stroke(scale, with: .color(.white), lineWidth: 1.5)
            ctx.draw(
                Text(deg >= 1 ? String(format: "%.0f°", deg) : String(format: "%.0f′", deg * 60)).font(.caption)
                    .foregroundColor(.white),
                at: CGPoint(x: size.width - 12 - bar / 2, y: y0 - 6), anchor: .bottom)
            // The Moon, with its bright limb marked.
            let r = sim.moonRadiusArcsec
            let disk = CGRect(x: ox - k * r, y: oy - k * r, width: 2 * k * r, height: 2 * k * r)
            ctx.fill(Path(ellipseIn: disk), with: .color(Color(white: 0.18)))
            if let limb = sim.brightLimbDeg, let i = sim.phaseAngleNowDeg {
                // The sunlit part; the rest is the dark side.
                let outline = Ephemeris.litOutline(brightLimbFromZenithDeg: limb, phaseAngleDeg: i)
                var lit = Path()
                lit.addLines(outline.map { pt(CGPoint(x: $0.x * r, y: $0.y * r)) })
                lit.closeSubpath()
                ctx.fill(lit, with: .color(Color(white: 0.55)))
            }
            if let limb = sim.brightLimbDeg {
                let a = limb * .pi / 180
                var lit = Path()
                lit.addArc(
                    center: CGPoint(x: ox, y: oy), radius: k * r,
                    startAngle: .radians(a - .pi / 2 - .pi / 2), endAngle: .radians(a - .pi / 2 + .pi / 2),
                    clockwise: false)
                ctx.stroke(lit, with: .color(.yellow), lineWidth: 3)
            }
            // Path and frame.
            if sim.trail.count > 1 {
                var path = Path()
                path.move(to: pt(sim.trail[0]))
                for p in sim.trail.dropFirst() { path.addLine(to: pt(p)) }
                ctx.stroke(path, with: .color(.cyan.opacity(0.6)), lineWidth: 1)
            }
            if sim.footprint.count == 4 {
                var frame = Path()
                frame.move(to: pt(sim.footprint[0]))
                for p in sim.footprint.dropFirst() { frame.addLine(to: pt(p)) }
                frame.closeSubpath()
                ctx.stroke(frame, with: .color(.red), lineWidth: 2)
                // The frame's top edge, so its turn shows.
                var top = Path()
                top.move(to: pt(sim.footprint[0]))
                top.addLine(to: pt(sim.footprint[1]))
                ctx.stroke(top, with: .color(.orange), lineWidth: 3)
            }
            ctx.draw(
                Text(String(format: "camera %.0f″, %.0f″ from the Moon's centre", sim.pointing.x, sim.pointing.y))
                    .font(.caption).foregroundColor(.white),
                at: CGPoint(x: 10, y: 10), anchor: .topLeading)
        }
    }
}
