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
                    "Moon-centred: x along azimuth, y along altitude. The rectangle is the search area around where the mount started; the box is the camera's frame; the line is its path."
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(10)
        }
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
                        ForEach(sim.library, id: \.self) { Text($0.lastPathComponent).tag(Optional($0)) }
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
                Slider(value: $sim.glowLevel, in: 0...0.2, step: 0.01) {
                    Text(String(format: "Glow %.2f", sim.glowLevel))
                }
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
            // Fit the search area and the Moon, with a margin.
            let reach = sim.reachArcsec
            let centre = sim.searchCentre
            let minX = min(centre.x - reach, -sim.moonRadiusArcsec) - 600
            let maxX = max(centre.x + reach, sim.moonRadiusArcsec) + 600
            let minY = min(centre.y - 0.6 * reach, -sim.moonRadiusArcsec) - 600
            let maxY = max(centre.y + 0.6 * reach, sim.moonRadiusArcsec) + 600
            let k = min(size.width / (maxX - minX), size.height / (maxY - minY))
            let ox = size.width / 2 - k * (minX + maxX) / 2
            let oy = size.height / 2 + k * (minY + maxY) / 2
            func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: ox + k * p.x, y: oy - k * p.y) }

            // Search area.
            let area = CGRect(
                x: pt(CGPoint(x: centre.x - reach, y: centre.y + 0.6 * reach)).x,
                y: pt(CGPoint(x: centre.x - reach, y: centre.y + 0.6 * reach)).y,
                width: 2 * reach * k, height: 1.2 * reach * k)
            ctx.stroke(Path(area), with: .color(.gray), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
            // The Moon, with its bright limb marked.
            let r = sim.moonRadiusArcsec
            let disk = CGRect(x: ox - k * r, y: oy - k * r, width: 2 * k * r, height: 2 * k * r)
            ctx.fill(Path(ellipseIn: disk), with: .color(Color(white: 0.35)))
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
