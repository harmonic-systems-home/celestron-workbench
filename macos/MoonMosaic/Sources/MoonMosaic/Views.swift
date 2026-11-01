import AppKit
import MoonMosaicCore
import SwiftUI

/// Dark red on black at night; ordinary colours by day.
struct Palette {
    let background: Color
    let panel: Color
    let text: Color
    let dim: Color
    let bright: Color
    let imageTint: Color

    static let night = Palette(
        background: .black, panel: Color(red: 0.07, green: 0, blue: 0),
        text: Color(red: 0.72, green: 0.1, blue: 0.07),
        dim: Color(red: 0.38, green: 0.04, blue: 0.03),
        bright: Color(red: 1, green: 0.28, blue: 0.12),
        imageTint: Color(red: 1, green: 0.15, blue: 0.1))
    static let day = Palette(
        background: Color(nsColor: .windowBackgroundColor),
        panel: Color(nsColor: .controlBackgroundColor), text: .primary, dim: .secondary,
        bright: .orange, imageTint: .white)
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @State private var panel = Panel.camera

    enum Panel { case camera, focus, preview }

    var palette: Palette { model.isNight ? .night : .day }

    var body: some View {
        VStack(spacing: 12) {
            if let alarm = model.linkAlarm { alarmBanner(alarm) }
            HStack(alignment: .top, spacing: 14) {
                controls.frame(width: 300)
                VStack(spacing: 12) {
                    imagePanel
                    HStack(alignment: .top, spacing: 12) {
                        TileGrid(model: model, palette: palette).frame(width: 340, height: 220)
                        logPanel
                    }
                    .frame(height: 220)
                }
            }
        }
        .padding(16)
        .background(palette.background)
        .foregroundStyle(palette.text)
        .font(.system(size: 17, design: .rounded))
        .preferredColorScheme(model.isNight ? .dark : .light)
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model, palette: palette) }
    }

    /// Loud in either palette: the one thing that mustn't be missed.
    private func alarmBanner(_ alarm: LinkAlarm) -> some View {
        HStack(spacing: 16) {
            Image(systemName: "exclamationmark.octagon.fill").font(.system(size: 34))
            Text(alarm.text).font(.system(size: 19, weight: .semibold, design: .rounded))
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            if model.alarmSounding {
                Button("Silence") { model.silenceAlarm() }
                    .font(.system(size: 17, weight: .semibold))
            }
        }
        .foregroundStyle(.white)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(red: 0.75, green: 0, blue: 0)))
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(model.mountState).font(.system(size: 22, weight: .semibold, design: .rounded))
                if let alt = model.altitude {
                    Text(String(format: "Tube altitude %.2f°", alt)).foregroundStyle(palette.dim)
                }
                Text(model.busy.map { "\($0)…" } ?? "Ready").foregroundStyle(
                    model.busy == nil ? palette.dim : palette.bright)
                if let finish = model.finishAt {
                    Text(progress(finish: finish)).foregroundStyle(palette.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 6)

            if model.connected {
                button("Disconnect", enabled: model.busy == nil) { model.disconnect() }
            } else {
                button(
                    model.simulate ? "Connect (simulated)" : "Connect", enabled: model.busy == nil
                ) {
                    model.connect()
                }
            }
            Text("Centre the Moon with the arrow keys (rate 5), then:")
                .font(.system(size: 13, design: .rounded)).foregroundStyle(palette.dim)
            button("1  Here", enabled: model.connected && model.busy == nil) { model.here() }
            button(
                model.holding ? "Holding (tap to release)" : "Hold on Moon",
                enabled: model.hereSet && model.busy == nil
            ) { model.toggleHold() }
            button("2  Calibrate", enabled: model.hereSet && model.busy == nil) {
                model.calibrate()
            }
            button("3  Plan", enabled: model.calibrated && model.busy == nil) { model.makePlan() }
            button("4  Start", enabled: model.plan != nil && model.busy == nil) { model.start() }
            HStack(spacing: 10) {
                button("Pause", enabled: model.busy == "Capturing") { model.pause() }
                button("Stop", enabled: model.connected) { model.stop() }
            }
            button("Preview", enabled: model.plan != nil && model.busy == nil) {
                model.makePreview()
                panel = .preview
            }
            button(
                model.selected.isEmpty ? "Redo selected" : "Redo \(model.selected.count) selected",
                enabled: !model.selected.isEmpty && model.busy == nil
            ) { model.redoSelected() }
            Spacer()
            button("Settings", enabled: model.busy == nil) { model.showSettings = true }
        }
    }

    /// Tiles done, minutes left (rounded up) and the finish time to the minute.
    private func progress(finish: Date) -> String {
        let minutes = max(1, Int((finish.timeIntervalSinceNow / 60).rounded(.up)))
        let at = finish.formatted(date: .omitted, time: .shortened)
        return
            "\(model.captureDone) of \(model.captureTotal) tiles\nAbout \(minutes) min left, done ≈ \(at)"
    }

    private func button(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 19, weight: .semibold, design: .rounded))
                .frame(maxWidth: .infinity, minHeight: 52)
        }
        .buttonStyle(BigButton(palette: palette))
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    // MARK: Image

    private var imagePanel: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                Picker("", selection: $panel) {
                    Text("Camera").tag(Panel.camera)
                    Text("Focus").tag(Panel.focus)
                    Text("Mosaic preview").tag(Panel.preview)
                }
                .pickerStyle(.segmented)
                .frame(width: 400)
                Spacer()
                stepper(
                    exposureText, enabled: model.busy == nil,
                    down: { model.stepExposure(-1) }, up: { model.stepExposure(1) })
                stepper(
                    "Gain \(model.gain)", enabled: model.busy == nil,
                    down: { model.stepGain(-1) }, up: { model.stepGain(1) })
            }
            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10).fill(palette.panel)
                if let image = shownImage {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(panel == .focus ? .none : .medium)
                        .aspectRatio(contentMode: .fit)
                        .colorMultiply(palette.imageTint)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Text(panel == .preview ? "No preview yet" : "No camera image")
                        .foregroundStyle(palette.dim)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                if panel == .focus, let s = model.focusSharpness {
                    focusReadout(s)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var shownImage: CGImage? {
        switch panel {
        case .camera: model.liveImage
        case .focus: model.focusImage
        case .preview: model.previewImage
        }
    }

    private var exposureText: String {
        let e = model.exposureMs
        return "Exposure " + (e < 10 ? String(format: "%.1f ms", e) : String(format: "%.0f ms", e))
    }

    /// Sharpness now and the best so far (reset by a change of exposure or
    /// gain, which changes the scale, or by hand).
    private func focusReadout(_ sharpness: Double) -> some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: "Sharpness %.0f", sharpness))
                    .font(.system(size: 28, weight: .semibold, design: .rounded))
                    .foregroundStyle(
                        sharpness >= 0.97 * model.bestFocus ? palette.bright : palette.text)
                Text(String(format: "Best %.0f", model.bestFocus)).foregroundStyle(palette.dim)
            }
            Button("Reset best") { model.resetBestFocus() }
                .buttonStyle(BigButton(palette: palette))
                .frame(width: 130, height: 44)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.background.opacity(0.75)))
        .padding(14)
    }

    private func stepper(
        _ title: String, enabled: Bool, down: @escaping () -> Void, up: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(title).monospacedDigit().frame(minWidth: 140, alignment: .trailing)
            ForEach([("−", down), ("+", up)], id: \.0) { label, action in
                Button(action: action) {
                    Text(label).font(.system(size: 24, weight: .semibold, design: .rounded))
                        .frame(width: 48, height: 40)
                }
                .buttonStyle(BigButton(palette: palette))
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
    }

    private var logPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(Array(model.log.enumerated()), id: \.offset) { i, line in
                        Text(line).font(.system(size: 13, design: .monospaced)).id(i)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 10).fill(palette.panel))
            .onChange(of: model.log.count) { _, n in proxy.scrollTo(n - 1, anchor: .bottom) }
        }
    }
}

/// The plan's tiles, coloured by state; tap to select for Redo.
struct TileGrid: View {
    @ObservedObject var model: AppModel
    let palette: Palette

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(palette.panel)
                if let plan = model.plan {
                    let layout = Layout(plan: plan, size: geo.size)
                    ForEach(plan.tiles) { tile in
                        let r = layout.rect(tile)
                        Rectangle()
                            .fill(color(tile.id).opacity(0.55))
                            .overlay(
                                Rectangle().stroke(
                                    model.selected.contains(tile.id) ? palette.bright : palette.dim,
                                    lineWidth: model.selected.contains(tile.id) ? 3 : 1)
                            )
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                            .onTapGesture {
                                if model.selected.contains(tile.id) {
                                    model.selected.remove(tile.id)
                                } else {
                                    model.selected.insert(tile.id)
                                }
                            }
                    }
                    Circle()
                        .stroke(palette.dim, lineWidth: 1)
                        .frame(width: layout.moonDiameter, height: layout.moonDiameter)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                        .allowsHitTesting(false)
                } else {
                    Text("Tiles appear after Plan").foregroundStyle(palette.dim)
                }
            }
        }
    }

    private func color(_ id: Int) -> Color {
        switch model.tileStates[id] {
        case .done: palette.text
        case .moving, .capturing: palette.bright
        case .failed: .orange
        default: palette.background
        }
    }

    /// Plan pixels to view points, centred on the Moon.
    struct Layout {
        let scale: Double
        let size: CGSize
        let tileSize: CGSize
        let moonDiameter: Double

        init(plan: MosaicPlan, size: CGSize) {
            let xs = plan.tiles.map { abs($0.center.x) + Double(plan.frameWidth) / 2 }
            let ys = plan.tiles.map { abs($0.center.y) + Double(plan.frameHeight) / 2 }
            let spanX = 2 * (xs.max() ?? 1)
            let spanY = 2 * (ys.max() ?? 1)
            scale = min((size.width - 12) / spanX, (size.height - 12) / spanY)
            self.size = size
            tileSize = CGSize(
                width: Double(plan.frameWidth) * scale, height: Double(plan.frameHeight) * scale)
            moonDiameter = 2 * plan.moonRadiusPixels * scale
        }

        func rect(_ tile: Tile) -> CGRect {
            let cx = size.width / 2 + tile.center.x * scale
            let cy = size.height / 2 + tile.center.y * scale
            return CGRect(
                x: cx - tileSize.width / 2, y: cy - tileSize.height / 2, width: tileSize.width,
                height: tileSize.height)
        }
    }
}

struct BigButton: ButtonStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? palette.background : palette.text)
            .background(
                RoundedRectangle(cornerRadius: 12).fill(
                    configuration.isPressed ? palette.bright : palette.panel)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(palette.dim, lineWidth: 1.5))
            .contentShape(Rectangle())
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    let palette: Palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Site (stays on this Mac)") {
                TextField("Latitude (north +)", value: $model.latitude, format: .number)
                TextField("Longitude (east +)", value: $model.longitude, format: .number)
            }
            Section("Optics and camera") {
                TextField("Focal length (mm)", value: $model.focalLengthMm, format: .number)
                TextField("Exposure (ms)", value: $model.exposureMs, format: .number)
                TextField("Gain", value: $model.gain, format: .number)
            }
            Section("Mosaic") {
                Slider(value: $model.overlap, in: 0.15...0.4, step: 0.05) {
                    Text("Overlap \(Int(model.overlap * 100))%")
                }
                Stepper(
                    "Video per tile: \(String(format: "%.1f", model.videoSeconds)) s",
                    value: $model.videoSeconds, in: 1...10, step: 0.5)
            }
            Section("Session") {
                Toggle("Rehearse with the simulated mount and camera", isOn: $model.simulate)
                    .disabled(model.connected)
                Picker("Palette", selection: $model.paletteMode) {
                    Text("Auto (red after dusk)").tag("auto")
                    Text("Day").tag("day")
                    Text("Night (red)").tag("night")
                }
                HStack {
                    Text(model.folder.path).font(.system(size: 12, design: .monospaced))
                        .lineLimit(2)
                    Spacer()
                    Button("Choose…") { choose() }
                }
            }
            HStack {
                Spacer()
                Button("Done") {
                    // Ends editing first, so a number typed without Return
                    // is kept.
                    NSApp.keyWindow?.makeFirstResponder(nil)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 760)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.folder
        if panel.runModal() == .OK, let url = panel.url { model.folder = url }
    }
}
