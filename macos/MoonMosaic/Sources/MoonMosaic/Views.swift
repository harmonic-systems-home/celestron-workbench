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
            flowStrip
            HStack(alignment: .top, spacing: 14) {
                // Scrolls on its own so the long button column stays reachable
                // on a short laptop screen.
                VStack(alignment: .leading, spacing: 6) {
                    statusPanel.frame(width: 300)
                    ScrollView(.vertical) {
                        controls.frame(width: 300)
                    }
                    .scrollIndicators(.automatic)
                }
                .frame(width: 300)
                VStack(spacing: 12) {
                    imagePanel
                    HStack(alignment: .top, spacing: 12) {
                        // The plan's area shows the search while one runs, or
                        // until there is a plan.
                        Group {
                            if let progress = model.searchProgress, model.searching || model.plan == nil {
                                SearchMap(model: model, sim: model.simulator, progress: progress)
                            } else {
                                TileGrid(model: model, palette: palette)
                            }
                        }
                        .frame(width: 340, height: 220)
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
        .onChange(of: model.showPreviewRequest) { panel = .preview }
        .sheet(isPresented: $model.showSettings) { SettingsView(model: model, palette: palette) }
        .alert(
            "Not enough disk space",
            isPresented: Binding(
                get: { model.diskWarning != nil }, set: { if !$0 { model.diskWarning = nil } })
        ) {
            Button("Capture anyway", role: .destructive) { model.startDespiteDisk() }
            Button("Cancel", role: .cancel) { model.diskWarning = nil }
        } message: {
            Text(model.diskWarning ?? "")
        }
    }

    /// The live frame's brightness (ADR 0022 amendment 7's Light readout):
    /// what the search's detector sees, and where the exposure sits.
    private func brightnessPanel(_ st: FrameStats) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(st.moonInView ? Color.green : Color.gray).frame(width: 10, height: 10)
                Text(st.moonInView ? "Moon in view" : "No Moon").font(.system(size: 12, weight: .semibold))
            }
            Canvas { ctx, size in
                let top = max(st.histogram.dropFirst().max() ?? 0.01, 0.001)
                let w = size.width / Double(st.histogram.count)
                for (i, v) in st.histogram.enumerated() {
                    // Log-ish height so small lit areas show beside the dark sky.
                    let h = min(1, sqrt(v / top)) * size.height
                    ctx.fill(
                        Path(CGRect(x: Double(i) * w, y: size.height - h, width: max(w - 0.5, 0.5), height: h)),
                        with: .color(i == 63 && v > 0 ? .red : .white.opacity(0.8)))
                }
            }
            .frame(width: 150, height: 50)
            .background(Color.black.opacity(0.6))
            Group {
                Text("Peak \(st.peak)  mean \(String(format: "%.0f", st.mean))")
                Text(String(format: "Lit %.0f%%  clipped %.2f%%", st.lit * 100, st.clipped * 100))
                Text("Sky \(String(format: "%d", st.background)), \(st.skyName) trigger").foregroundStyle(.gray)
            }
            .font(.system(size: 11, design: .monospaced))
        }
        .foregroundStyle(.white)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55)))
        .padding(12)
        .allowsHitTesting(false)
    }

    /// The guided flow (ADR 0022 amendment 7): done, running and to come.
    /// Steps done by hand are marked by clicking them.
    private var flowStrip: some View {
        HStack(spacing: 4) {
            ForEach(FlowStep.allCases) { step in
                let done = model.flowDone.contains(step)
                let active = model.flowActive == step || (step == .track && model.following)
                Text(step.title)
                    .font(.system(size: 13, weight: active ? .semibold : .regular, design: .rounded))
                    .lineLimit(1)
                    .padding(.horizontal, 8).padding(.vertical, 5)
                    .frame(maxWidth: .infinity)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(done ? palette.bright.opacity(0.25) : Color.clear))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(active ? palette.bright : palette.dim.opacity(0.4), lineWidth: active ? 2 : 1))
                    .foregroundStyle(done || active ? palette.text : palette.dim)
                    .onTapGesture { if step.byHand { model.markDone(step) } }
                    .help(step.byHand ? "Click when done" : step.estimateSeconds.map { "Designed time \(Int($0)) s" } ?? "")
            }
        }
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

    /// The mount's status, above the scrolling buttons so it stays in view.
    private var statusPanel: some View {
        VStack(alignment: .leading, spacing: 3) {
                Text(model.mountState).font(.system(size: 22, weight: .semibold, design: .rounded))
                if model.connected {
                    let t = model.trackingStatus
                    Label(t.text, systemImage: t.symbol)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundStyle([Color.green, Color.orange, Color.blue, palette.dim][t.kind])
                }
                if let m = model.moveProgress {
                    VStack(alignment: .leading, spacing: 2) {
                        ProgressView(value: m.fraction).tint(.blue)
                        Text(
                            String(format: "%.1f° on %@, %.0f%%", m.degrees, m.axis, m.fraction * 100)
                                + (m.eta.map { String(format: ", about %.0f s left", $0) } ?? "")
                        )
                        .font(.system(size: 12, design: .rounded)).foregroundStyle(palette.dim)
                    }
                }
                if let alt = model.altitude {
                    Text(String(format: "Tube altitude %.2f°", alt)).foregroundStyle(palette.dim)
                }
                if let b = model.battery, let summary = model.batterySummary {
                    Text("Mount battery \(summary)")
                        .foregroundStyle(b.level <= 1 && b.state != 2 ? palette.bright : palette.dim)
                }
                Text(model.busy.map { "\($0)…" } ?? "Ready").foregroundStyle(
                    model.busy == nil ? palette.dim : palette.bright)
                if let d = model.stepDetail {
                    Text(d).font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.bright)
                }
                if let finish = model.finishAt {
                    Text(progress(finish: finish)).foregroundStyle(palette.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 6)
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {

            if let reason = model.latchedReason {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Latched: \(reason).").font(.system(size: 15, weight: .semibold))
                    Text("The app stops any motion, so the arrow keys won't work, until you press Reset.")
                        .font(.system(size: 14))
                    button("Reset", enabled: true) { model.resetFault() }
                }
                .foregroundStyle(palette.bright)
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 10).stroke(palette.bright, lineWidth: 2))
            }

            if model.connected {
                button("Disconnect", enabled: model.busy == nil) { model.disconnect() }
            } else {
                button(
                    model.simulate ? "Connect (simulated)" : "Connect", enabled: model.busy == nil
                ) {
                    model.connect()
                }
            }
            if !model.testMode {
                button(
                    model.following ? "Tracking (tap to stop)" : "Track",
                    enabled: model.connected && (model.busy == nil || model.following)
                ) { model.toggleTrack() }
                panControls
                HStack(spacing: 10) {
                    button("Stop nudge", enabled: model.following) { model.stopNudge() }
                    button(
                        model.undoDepth > 0 ? "Undo (\(model.undoDepth))" : "Undo",
                        enabled: model.following && model.undoDepth > 0
                    ) { model.undo() }
                }
            }
            searchControls
            if !model.testMode {
                HStack(spacing: 10) {
                    button("Here", enabled: model.connected && model.busy == nil) { model.here() }
                    button(
                        model.holding ? "Locked" : "Lock",
                        enabled: model.hereSet && model.busy == nil
                    ) { model.toggleHold() }
                }
                Text("Find sets Here by itself; press Here after centring by hand. Lock holds a fixed aim.")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(palette.dim)
                button("Orient Camera", enabled: model.connected && model.busy == nil) {
                    model.calibrate()
                }
                button(
                    model.centreFound ? "Orient Moon (found)" : "Orient Moon",
                    enabled: model.calibrated && model.busy == nil
                ) { model.findCentre() }
                button("Plan", enabled: model.calibrated && model.busy == nil) {
                    model.makePlan()
                }
                button("Start", enabled: model.plan != nil && model.busy == nil) { model.start() }
                button(
                    model.darkTiles > 0 ? "Earthshine: \(model.darkTiles) dark tiles" : "Earthshine",
                    enabled: model.darkTiles > 0 && model.busy == nil
                ) { model.startEarthshine() }
            }
            HStack(spacing: 10) {
                button("Pause", enabled: model.busy == "Capturing") { model.pause() }
                button("Stop", enabled: model.connected) { model.stop() }
            }
            if !model.testMode {
                button("Preview", enabled: model.plan != nil && model.busy == nil) {
                    model.makePreview()
                    panel = .preview
                }
                button(
                    model.selected.isEmpty
                        ? "Redo selected" : "Redo \(model.selected.count) selected",
                    enabled: !model.selected.isEmpty && model.busy == nil
                ) { model.redoSelected() }
            }
            if model.simulator.attached { SimulatorBox(model: model, sim: model.simulator, palette: palette) }
            Spacer(minLength: 12)
            button("Settings", enabled: model.busy == nil) { model.showSettings = true }
        }
    }

    /// Test-mode toggle, the spiral/raster choice, and the search buttons
    /// (ADR 0022). Click a spot in the camera view to recentre there.
    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Picker("Sky", selection: $model.searchSky) {
                Text("Auto").tag("auto")
                Text("Clear night").tag(Blob.Sky.clearNight.rawValue)
                Text("Cloudy night").tag(Blob.Sky.cloudyNight.rawValue)
                Text("Day").tag(Blob.Sky.day.rawValue)
            }
            .font(.system(size: 13, design: .rounded))
            .disabled(model.searching)
            Stepper(
                value: $model.searchReachDeg, in: 0.25...4, step: 0.25
            ) {
                Text(String(format: "Search area ±%.2g°", model.searchReachDeg))
                    .font(.system(size: 13, design: .rounded))
            }
            .disabled(model.searching)
            Toggle(isOn: $model.testMode) {
                Text("Test mode (drainpipe) — no tracking")
                    .font(.system(size: 13, design: .rounded))
            }
            .toggleStyle(.switch)
            .tint(palette.bright)
            .disabled(!model.connected || model.searching || model.busy != nil)

            Text(
                model.testMode
                    ? "Find a fixed target to try the search and focus. Aim the tube near \(Int(model.testAltitudeDeg))° altitude, then:"
                    : "Get close with the spotting scope, then search for the Moon:"
            )
            .font(.system(size: 13, design: .rounded)).foregroundStyle(palette.dim)

            Picker("", selection: $model.searchPattern) {
                Text("Spiral").tag(SearchPattern.spiral)
                Text("Raster").tag(SearchPattern.raster)
            }
            .pickerStyle(.segmented)
            .disabled(model.searching || model.busy != nil)

            HStack(spacing: 10) {
                button(
                    model.searching ? "Searching…" : "Search",
                    enabled: model.connected && model.busy == nil && !model.searching
                ) { model.startSearch() }
                button("I see it", enabled: model.searching) { model.sawIt() }
            }
            button("Stop search", enabled: model.searching) { model.stopSearch() }
        }
    }

    /// Tiles done, minutes left (rounded up) and the finish time to the minute.
    private func progress(finish: Date) -> String {
        let minutes = max(1, Int((finish.timeIntervalSinceNow / 60).rounded(.up)))
        let at = finish.formatted(date: .omitted, time: .shortened)
        return
            "\(model.captureDone) of \(model.captureTotal) tiles\nAbout \(minutes) min left, done ≈ \(at)"
    }

    /// Pan the view without the hand controller: a quarter frame per press,
    /// or a twelfth with Fine; Centre returns to the Moon's centre.
    @State private var fineP = false
    private var panControls: some View {
        let step = fineP ? 1.0 / 12 : 0.25
        let on = model.connected && (model.busy == nil || model.holding || model.following)
        return HStack(spacing: 6) {
            ForEach(
                [("◀", -step, 0.0), ("▲", 0.0, -step), ("▼", 0.0, step), ("▶", step, 0.0)], id: \.0
            ) { item in
                Button(item.0) { model.pan(item.1, item.2) }
                    .buttonStyle(BigButton(palette: palette))
                    .frame(minWidth: 44, minHeight: 40)
                    .disabled(!on).opacity(on ? 1 : 0.35)
            }
            Button("Centre") { model.centreAim() }
                .buttonStyle(BigButton(palette: palette))
                .frame(minHeight: 40)
                .disabled(!(on && model.hereSet)).opacity(on && model.hereSet ? 1 : 0.35)
            Toggle("Fine", isOn: $fineP).toggleStyle(.checkbox).fixedSize()
        }
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
            .overlay(alignment: .topTrailing) {
                if panel == .camera, let st = model.frameStats { brightnessPanel(st) }
            }
            .overlay {
                // Only once the camera is oriented: before that a click can't
                // be turned into a move on the sky reliably.
                if panel == .camera, model.connected, model.calibrated, let img = model.liveImage {
                    clickToRecentre(img)
                }
            }
            if panel == .camera {
                Text(
                    model.calibrated
                        ? "Click the image to recentre there and search finer."
                        : "Click-to-recentre works once the camera is oriented.")
                    .font(.system(size: 12, design: .rounded)).foregroundStyle(palette.dim)
            }
            if panel == .focus {
                focusGraph().frame(height: 96)
            }
        }
    }

    /// A line graph of the recent sharpness trace (ADR 0022), so the operator
    /// can run a manual binary search on the focus knob and watch the trend.
    /// A dashed line marks the best settled sharpness to return to; the badge
    /// says whether the image has settled (touch-shake gone) or is still
    /// shaking, so only settled readings are trusted.
    private func focusGraph() -> some View {
        let values = model.focusHistory.map(\.sharpness)
        return ZStack(alignment: .topTrailing) {
            RoundedRectangle(cornerRadius: 10).fill(palette.panel)
            if values.count >= 2 {
                GeometryReader { geo in
                    let maxV = max(values.max() ?? 1, 1)
                    let dx = geo.size.width / CGFloat(max(values.count - 1, 1))
                    let yOf: (Double) -> CGFloat = { v in
                        geo.size.height * (1 - CGFloat(max(0, min(1, v / maxV))))
                    }
                    if model.bestFocus > 0 {
                        Path { p in
                            let y = yOf(model.bestFocus)
                            p.move(to: CGPoint(x: 0, y: y))
                            p.addLine(to: CGPoint(x: geo.size.width, y: y))
                        }
                        .stroke(palette.dim, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                    Path { p in
                        for (i, v) in values.enumerated() {
                            let pt = CGPoint(x: CGFloat(i) * dx, y: yOf(v))
                            if i == 0 { p.move(to: pt) } else { p.addLine(to: pt) }
                        }
                    }
                    .stroke(palette.bright, lineWidth: 2)
                }
                .padding(8)
            } else {
                Text("Sharpness trace — turn the focus knob")
                    .foregroundStyle(palette.dim)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            Text(model.focusSettled ? "settled" : "shaking")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(model.focusSettled ? palette.bright : palette.dim)
                .padding(8)
        }
    }

    /// A transparent layer over the camera image that turns a click into a
    /// recentre (ADR 0022): the click's position as a fraction of the shown
    /// image (aspect-fit inside the panel, 6 pt padding) goes to the model.
    private func clickToRecentre(_ img: CGImage) -> some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SpatialTapGesture().onEnded { value in
                        if let f = recentreFraction(
                            at: value.location, in: geo.size, image: img)
                        {
                            model.recentre(fraction: f)
                        }
                    })
        }
    }

    /// The click's offset from the image centre, each axis in −0.5…0.5 of the
    /// shown image, or nil when the click is outside the image.
    private func recentreFraction(at point: CGPoint, in size: CGSize, image img: CGImage) -> CGSize?
    {
        let pad = 6.0
        let (availW, availH) = (size.width - 2 * pad, size.height - 2 * pad)
        guard availW > 0, availH > 0, img.height > 0 else { return nil }
        let aspect = Double(img.width) / Double(img.height)
        var (w, h) = (availW, availW / aspect)
        if h > availH { (w, h) = (availH * aspect, availH) }
        let (rectX, rectY) = ((size.width - w) / 2, (size.height - h) / 2)
        let fx = (point.x - rectX) / w - 0.5
        let fy = (point.y - rectY) / h - 0.5
        guard abs(fx) <= 0.5, abs(fy) <= 0.5 else { return nil }
        return CGSize(width: fx, height: fy)
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
    @Environment(\.openWindow) private var openWindow
    let palette: Palette
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Form {
            Section("Site (stays on this Mac)") {
                TextField("Latitude (north +)", value: $model.latitude, format: .number)
                TextField("Longitude (east +)", value: $model.longitude, format: .number)
                Toggle(
                    "Set the hand controller's time and site when connecting",
                    isOn: $model.setHandController
                )
                .disabled(model.connected)
            }
            Section("Optics and camera") {
                TextField("Focal length (mm)", value: $model.focalLengthMm, format: .number)
                TextField("Exposure (ms)", value: $model.exposureMs, format: .number)
                TextField("Gain", value: $model.gain, format: .number)
            }
            Section("Finding the centre (survey)") {
                TextField("Survey exposure (ms)", value: $model.surveyExposureMs, format: .number)
                TextField("Survey gain", value: $model.surveyGain, format: .number)
                Text("Long enough for earthshine to show above the sky; the sunlit part can saturate.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Search (ADR 0022)") {
                Picker("Pattern", selection: $model.searchPattern) {
                    Text("Spiral").tag(SearchPattern.spiral)
                    Text("Raster").tag(SearchPattern.raster)
                }
                TextField("Step between stops (°)", value: $model.searchStepDeg, format: .number)
                TextField("Reach from the start (°)", value: $model.searchReachDeg, format: .number)
                Text("The step can be wider than the frame — the Moon's glow shows before its disk.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Test mode (drainpipe): find a fixed target, no tracking", isOn: $model.testMode)
                    .disabled(model.searching)
                TextField("Test target altitude (°)", value: $model.testAltitudeDeg, format: .number)
                Text("Aim the tube roughly here first; it ties the encoder to the sky for the motion envelope.")
                    .font(.caption).foregroundStyle(.secondary)
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
                Toggle("Simulated camera with the real mount", isOn: $model.simulatedCamera)
                    .disabled(model.connected || model.simulate)
                Button("Open the simulator window") { openWindow(id: "simulator") }
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

/// The simulator's main settings, in the main window while simulating: the
/// scene (from the scene library) and the rehearsal speed. Everything else
/// is in the simulator window.
struct SimulatorBox: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sim: SimulatorModel
    let palette: Palette
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Simulator").font(.system(size: 15, weight: .semibold, design: .rounded))
            Picker("Scene", selection: $sim.libraryScene) {
                ForEach(sim.library, id: \.self) { url in
                    Text(url.deletingPathExtension().lastPathComponent).tag(Optional(url))
                }
            }
            .onChange(of: sim.libraryScene) { if sim.sceneChoice != .library { sim.sceneChoice = .library } }
            .disabled(sim.library.isEmpty)
            if sim.loadingScene { ProgressView().controlSize(.small) }
            Text(sim.sceneNote).font(.system(size: 11)).foregroundStyle(palette.dim).lineLimit(2)
            HStack {
                Text("Speed \(Int(sim.speed))×").font(.system(size: 13))
                Slider(value: $sim.speed, in: 1...10, step: 1).disabled(!model.simulate)
            }
            HStack {
                Button("Random scenario") { sim.randomize(reachDeg: model.searchReachDeg) }
                Button("More…") { openWindow(id: "simulator") }
            }
            .font(.system(size: 13))
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).stroke(palette.dim.opacity(0.5), lineWidth: 1))
    }
}
