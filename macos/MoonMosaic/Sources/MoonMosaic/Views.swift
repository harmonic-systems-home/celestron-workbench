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

    /// The control column's width.
    static let leftWidth: CGFloat = 360

    /// The pointing panel's view, chosen by the phase: the search's field
    /// until the camera is oriented, then the Moon.
    private var autoMoonView: Bool { (model.calibrated || model.plan != nil) && !model.searching }
    @State private var mapOverride: Bool?
    private var showMoonView: Bool { mapOverride ?? autoMoonView }
    /// Where Here puts the Moon, as the camera's aim from its centre (″).
    private var estimate: SkyEstimate? {
        model.moonMap.map { SkyEstimate(aim: CGPoint(x: $0.aimSky.x, y: $0.aimSky.y), radiusArcsec: $0.radiusArcsec) }
    }

    var palette: Palette { model.isNight ? .night : .day }

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            // Sized to fit a 13-inch laptop's screen without scrolling; it
            // scrolls only if something extra (a latch) pushes it over.
            VStack(alignment: .leading, spacing: 6) {
                // A fixed height, so the buttons below don't jump as
                // lines (a move's progress, a step's detail) come and go.
                statusPanel.frame(width: Self.leftWidth, height: 150, alignment: .top).clipped()
                ScrollView(.vertical) {
                    controls.frame(width: Self.leftWidth)
                }
                .scrollIndicators(.automatic)
            }
            .frame(width: Self.leftWidth)
            VStack(spacing: 10) {
                if let alarm = model.linkAlarm { alarmBanner(alarm) }
                flowStrip
                imagePanel
                HStack(alignment: .top, spacing: 12) {
                    // Finding and placing the Moon: the search's field (the
                    // simulator's sky, or the search's map), with the camera's
                    // frame and where Here puts the Moon. From Orient Camera
                    // on: the Moon map, zoomed to the Moon, with the plan.
                    // A click on the corner switch overrides until the next
                    // phase.
                    ZStack(alignment: .topTrailing) {
                        if showMoonView, model.moonMap != nil {
                            TileGrid(model: model, palette: palette)
                        } else if model.simulator.attached {
                            SkyMap(sim: model.simulator, steady: true, estimate: estimate)
                                .background(Color.black)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                        } else if let progress = model.searchProgress {
                            SearchMap(model: model, sim: model.simulator, progress: progress, estimate: estimate)
                        } else {
                            TileGrid(model: model, palette: palette)
                        }
                        if model.moonMap != nil {
                            Button { mapOverride = !showMoonView } label: {
                                Text(showMoonView ? "Sky view" : "Moon view")
                                    .font(.system(size: 11, weight: .semibold))
                                    .frame(width: 76, height: 20)
                            }
                            .buttonStyle(BigButton(palette: palette))
                            .padding(6)
                                .help("Switch until the next step changes it")
                        }
                    }
                    .onChange(of: autoMoonView) { mapOverride = nil }
                    .frame(width: 400, height: 250)
                    logPanel
                }
                .frame(height: 250)
            }
        }
        .padding(16)
        .background(palette.background)
        .foregroundStyle(palette.text)
        .font(.system(size: 13, design: .rounded))
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
                Text(model.mountState).font(.system(size: 18, weight: .semibold, design: .rounded))
                if model.connected {
                    let t = model.trackingStatus
                    Label(t.text, systemImage: t.symbol)
                        .font(.system(size: 13, weight: .semibold, design: .rounded))
                        .foregroundStyle([Color.green, Color.orange, Color.blue, palette.dim][t.kind])
                }
                if model.connected {
                    if let sv = model.savingNow {
                        Label(sv.product ? "\(sv.text) (\(sv.frames) frames)" : sv.text, systemImage: "record.circle")
                            .font(.system(size: 12, weight: .semibold, design: .rounded))
                            .foregroundStyle(sv.product ? Color.red : Color.orange)
                            .lineLimit(1)
                    } else {
                        Label("Not saving frames", systemImage: "circle")
                            .font(.system(size: 11, design: .rounded)).foregroundStyle(palette.dim)
                    }
                }
                if let m = model.moveProgress {
                    VStack(alignment: .leading, spacing: 2) {
                        ProgressView(value: m.fraction).tint(.blue)
                        Text(
                            String(format: "%.1f° on %@, %.0f%%", m.degrees, m.axis, m.fraction * 100)
                                + (m.eta.map { String(format: ", about %.0f s left", $0) } ?? "")
                        )
                        .font(.system(size: 11, design: .rounded)).foregroundStyle(palette.dim)
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
                    Text(d).font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(palette.bright).lineLimit(2)
                }
                if let finish = model.finishAt {
                    Text(progress(finish: finish)).foregroundStyle(palette.text)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, 6)
    }

    private var controls: some View {
        let idle = model.busy == nil
        let aimed = model.calibrated && model.hereSet && idle
        return VStack(alignment: .leading, spacing: 6) {

            if let reason = model.latchedReason {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Latched: \(reason).").font(.system(size: 13, weight: .semibold))
                    Text("The app stops any motion, so the arrow keys won't work, until you press Reset.")
                        .font(.system(size: 12))
                    button("Reset", enabled: true) { model.resetFault() }
                }
                .foregroundStyle(palette.bright)
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 8).stroke(palette.bright, lineWidth: 2))
            }

            row {
                if model.connected {
                    button("Disconnect", enabled: idle) { model.disconnect() }
                } else {
                    button(model.simulate ? "Connect (simulated)" : "Connect", enabled: idle) {
                        model.connect()
                    }
                }
                if !model.testMode {
                    button(
                        model.following ? "Stop tracking" : "Track",
                        enabled: model.connected && (idle || model.following)
                    ) { model.toggleTrack() }
                    .help(model.following ? "Tracking: click to stop" : "Track the Moon")
                }
            }
            if !model.testMode {
                HStack(alignment: .center, spacing: 12) {
                    panControls
                    VStack(spacing: 6) {
                        Toggle("Fine nudges", isOn: $fineP).toggleStyle(.checkbox)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        button("Stop nudge", enabled: model.following) { model.stopNudge() }
                        button(
                            model.undoDepth > 0 ? "Undo (\(model.undoDepth))" : "Undo",
                            enabled: model.following && model.undoDepth > 0
                        ) { model.undo() }
                    }
                }
            }
            searchControls
            if !model.testMode {
                row {
                    button("Here", enabled: model.connected && idle) { model.here() }
                        .help("Find sets Here by itself; press Here after centring by hand.")
                    button(model.holding ? "Locked" : "Lock", enabled: model.hereSet && idle) {
                        model.toggleHold()
                    }
                    .help("Lock holds a fixed aim.")
                    button("Auto exposure", enabled: model.connected && idle) { model.autoSetExposure() }
                }
                row {
                    button("Orient Camera", enabled: model.connected && idle) { model.calibrate() }
                    button(model.centreFound ? "Orient Moon ✓" : "Orient Moon", enabled: model.calibrated && idle) {
                        model.findCentre()
                    }
                    button("Recheck", enabled: model.centreFound && idle) { model.recheck() }
                        .help("Recheck the Moon's place after fine focus")
                }
                HStack(spacing: 6) {
                    Text("Go to").foregroundStyle(palette.dim).frame(width: 40, alignment: .leading)
                    button("Limb", enabled: aimed) { model.goTo(.limb) }
                    button("Terminator", enabled: aimed) { model.goTo(.terminator) }
                    button(model.bestCrater ?? "Crater", enabled: aimed && model.bestCrater != nil) {
                        model.goTo(.crater)
                    }
                }
                row {
                    button("Plan", enabled: model.calibrated && idle) { model.makePlan() }
                    button("Start", enabled: model.plan != nil && idle) { model.start() }
                    button(
                        model.darkTiles > 0 ? "Earthshine (\(model.darkTiles))" : "Earthshine",
                        enabled: model.darkTiles > 0 && idle
                    ) { model.startEarthshine() }
                    .help("Capture the dark-side tiles by earthshine")
                }
            }
            row {
                button("Pause", enabled: model.busy == "Capturing") { model.pause() }
                button("Stop", enabled: model.connected) { model.stop() }
                if !model.testMode {
                    button("Preview", enabled: model.plan != nil && idle) {
                        model.makePreview()
                        panel = .preview
                    }
                }
            }
            if !model.testMode {
                button(
                    model.selected.isEmpty ? "Redo selected tiles" : "Redo \(model.selected.count) selected",
                    enabled: !model.selected.isEmpty && idle
                ) { model.redoSelected() }
            }
            if model.simulate || model.simulatedCamera || model.simulator.attached {
                SimulatorBox(model: model, sim: model.simulator, palette: palette)
            }
            button("Settings…", enabled: idle) { model.showSettings = true }
                .padding(.top, 4)
        }
    }

    private func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 6) { content() }
    }

    /// Test-mode toggle, the spiral/raster choice, and the search buttons
    /// (ADR 0022). Click a spot in the camera view to recentre there.
    private var searchControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Picker("Sky", selection: $model.searchSky) {
                    Text("Auto").tag("auto")
                    Text("Clear night").tag(Blob.Sky.clearNight.rawValue)
                    Text("Cloudy night").tag(Blob.Sky.cloudyNight.rawValue)
                    Text("Day").tag(Blob.Sky.day.rawValue)
                }
                .disabled(model.searching)
                Stepper(value: $model.searchReachDeg, in: 0.25...4, step: 0.25) {
                    Text(String(format: "Area ±%.2g°", model.searchReachDeg)).monospacedDigit()
                }
                .disabled(model.searching)
                .help("How far the search reaches from where the scope points")
            }
            HStack(spacing: 10) {
                Picker("", selection: $model.searchPattern) {
                    Text("Spiral").tag(SearchPattern.spiral)
                    Text("Raster").tag(SearchPattern.raster)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 150)
                .disabled(model.searching || model.busy != nil)
                Toggle(isOn: $model.testMode) { Text("Test mode") }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .tint(palette.bright)
                    .disabled(!model.connected || model.searching || model.busy != nil)
                    .help("Drainpipe test: a fixed target, no tracking")
            }
            if model.testMode {
                Text("Find a fixed target to try the search and focus. Aim the tube near \(Int(model.testAltitudeDeg))° altitude, then search.")
                    .font(.system(size: 11, design: .rounded)).foregroundStyle(palette.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
            row {
                button(
                    model.searching ? "Searching…" : "Search",
                    enabled: model.connected && model.busy == nil && !model.searching
                ) { model.startSearch() }
                .help("Get close with the spotting scope, then search for the Moon")
                button("I see it", enabled: model.searching) { model.sawIt() }
                button("Stop search", enabled: model.searching) { model.stopSearch() }
            }
        }
    }

    /// Tiles done, minutes left (rounded up) and the finish time to the minute.
    private func progress(finish: Date) -> String {
        let minutes = max(1, Int((finish.timeIntervalSinceNow / 60).rounded(.up)))
        let at = finish.formatted(date: .omitted, time: .shortened)
        return
            "\(model.captureDone) of \(model.captureTotal) tiles\nAbout \(minutes) min left, done ≈ \(at)"
    }

    /// Pan the view without the hand controller, laid out as a compass: a
    /// quarter frame per press, or a twelfth with Fine; the middle returns
    /// to the Moon's centre.
    @State private var fineP = false
    private var panControls: some View {
        let step = fineP ? 1.0 / 12 : 0.25
        let on = model.connected && (model.busy == nil || model.holding || model.following)
        let centreOn = on && model.hereSet
        func key(_ symbol: String, _ dx: Double, _ dy: Double, _ help: String) -> some View {
            Button { model.pan(dx, dy) } label: {
                Image(systemName: symbol).font(.system(size: 13, weight: .bold)).frame(width: 40, height: 24)
            }
            .buttonStyle(BigButton(palette: palette))
            .disabled(!on).opacity(on ? 1 : 0.35)
            .help(help)
        }
        return Grid(horizontalSpacing: 4, verticalSpacing: 4) {
            GridRow {
                Color.clear.frame(width: 40, height: 24)
                key("arrowtriangle.up.fill", 0, -step, "Move the view up")
                Color.clear.frame(width: 40, height: 24)
            }
            GridRow {
                key("arrowtriangle.left.fill", -step, 0, "Move the view left")
                Button { model.centreAim() } label: {
                    Image(systemName: "scope").font(.system(size: 13, weight: .bold)).frame(width: 40, height: 24)
                }
                .buttonStyle(BigButton(palette: palette))
                .disabled(!centreOn).opacity(centreOn ? 1 : 0.35)
                .help("Centre: back to the Moon's centre")
                key("arrowtriangle.right.fill", step, 0, "Move the view right")
            }
            GridRow {
                Color.clear.frame(width: 40, height: 24)
                key("arrowtriangle.down.fill", 0, step, "Move the view down")
                Color.clear.frame(width: 40, height: 24)
            }
        }
        .fixedSize()
    }

    private func button(_ title: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(.system(size: 13, weight: .semibold, design: .rounded))
                .lineLimit(1).minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 28)
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
                .frame(width: 300)
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
                        ? "Click the image to bring that point to the centre."
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
                .frame(width: 110, height: 28)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(palette.background.opacity(0.75)))
        .padding(14)
    }

    private func stepper(
        _ title: String, enabled: Bool, down: @escaping () -> Void, up: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 6) {
            Text(title).monospacedDigit().frame(minWidth: 110, alignment: .trailing)
            ForEach([("−", down), ("+", up)], id: \.0) { label, action in
                Button(action: action) {
                    Text(label).font(.system(size: 16, weight: .semibold, design: .rounded))
                        .frame(width: 30, height: 24)
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
                        Text(line).font(.system(size: 11, design: .monospaced)).id(i)
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

/// The Moon map: the Moon as the camera shows it, with the plan's tiles
/// (coloured by state; tap to select for Redo) and where the camera points
/// now, from Here on: the sky as seen by eye until the camera is oriented,
/// then as the camera sees it. While simulating, the true frame is dashed.
struct TileGrid: View {
    @ObservedObject var model: AppModel
    let palette: Palette

    var body: some View {
        GeometryReader { geo in
            ZStack {
                RoundedRectangle(cornerRadius: 10).fill(sky)
                if let layout = Layout(plan: model.plan, map: model.moonMap, size: geo.size) {
                    Canvas { ctx, size in
                        let c = layout.centre
                        let d = layout.moonDiameter
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: c.x - d / 2, y: c.y - d / 2, width: d, height: d)),
                            with: .color(darkSide))
                        let outline = model.moonMap?.outline ?? model.planOutline
                        if outline.count > 2 {
                            var lit = Path()
                            lit.addLines(outline.map(layout.point))
                            lit.closeSubpath()
                            ctx.fill(lit, with: .color(sunlit))
                        }
                    }
                    .allowsHitTesting(false)
                    if let plan = model.plan {
                        ForEach(plan.tiles) { tile in
                            let r = layout.rect(tile, plan)
                            Rectangle()
                                .fill(color(tile.id))
                                .contentShape(Rectangle())
                                .overlay(
                                    Rectangle().stroke(
                                        model.selected.contains(tile.id) ? palette.bright : grid,
                                        style: StrokeStyle(
                                            lineWidth: model.selected.contains(tile.id) ? 3 : 1,
                                            // Dark-side tiles (for the Earthshine pass) dashed.
                                            dash: tile.lit ? [] : [4, 3]))
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
                    }
                    Circle()
                        .stroke(grid, lineWidth: 1)
                        .frame(width: layout.moonDiameter, height: layout.moonDiameter)
                        .position(layout.centre)
                        .allowsHitTesting(false)
                    if let map = model.moonMap {
                        pointing(map, layout).allowsHitTesting(false)
                    }
                } else {
                    Text("The Moon map appears after Find or Here")
                        .foregroundStyle(grid)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
    }

    /// The camera's frame now, its path, and the truth while simulating; an
    /// arrow at the edge when the frame is off the map.
    private func pointing(_ map: MoonMap, _ layout: Layout) -> some View {
        Canvas { ctx, size in
            let bounds = CGRect(origin: .zero, size: size).insetBy(dx: 2, dy: 2)
            func poly(_ pts: [PixelOffset]) -> Path {
                var p = Path()
                p.addLines(pts.map(layout.point))
                p.closeSubpath()
                return p
            }
            if map.trail.count > 1 {
                var path = Path()
                path.addLines(map.trail.map(layout.point))
                ctx.stroke(path, with: .color(grid.opacity(0.5)), lineWidth: 1)
            }
            if let t = map.truthFrame {
                ctx.stroke(poly(t), with: .color(.cyan.opacity(0.8)), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                var top = Path()
                top.addLines([layout.point(t[0]), layout.point(t[1])])
                ctx.stroke(top, with: .color(.cyan.opacity(0.8)), lineWidth: 3)
            }
            do {
                let f = map.frame
                let path = poly(f)
                if bounds.intersects(path.boundingRect) {
                    ctx.stroke(path, with: .color(palette.bright), lineWidth: 2)
                    // The frame's top edge, so its turn shows (always the top
                    // in the camera's view, which this map is).
                    var top = Path()
                    top.addLines([layout.point(f[0]), layout.point(f[1])])
                    ctx.stroke(top, with: .color(palette.bright), lineWidth: 4)
                } else {
                    // Off the map: an arrow at the edge towards it.
                    let c = layout.point(PixelOffset(x: (f[0].x + f[2].x) / 2, y: (f[0].y + f[2].y) / 2))
                    let o = layout.centre
                    let (dx, dy) = (c.x - o.x, c.y - o.y)
                    let k = min(
                        (bounds.width / 2 - 14) / max(abs(dx), 1e-6), (bounds.height / 2 - 14) / max(abs(dy), 1e-6))
                    let tip = CGPoint(x: o.x + dx * k, y: o.y + dy * k)
                    let a = atan2(dy, dx)
                    var arrow = Path()
                    arrow.move(to: tip)
                    arrow.addLine(to: CGPoint(x: tip.x - 14 * cos(a - 0.4), y: tip.y - 14 * sin(a - 0.4)))
                    arrow.addLine(to: CGPoint(x: tip.x - 14 * cos(a + 0.4), y: tip.y - 14 * sin(a + 0.4)))
                    arrow.closeSubpath()
                    ctx.fill(arrow, with: .color(palette.bright))
                    let radii = hypot(dx, dy) / max(layout.moonDiameter / 2, 1)
                    ctx.draw(
                        Text(String(format: "%.1f radii", radii)).font(.system(size: 11)).foregroundColor(palette.bright),
                        at: CGPoint(x: tip.x - 26 * cos(a), y: tip.y - 26 * sin(a)))
                }
            }
            let note =
                map.oriented
                ? (map.truthFrame == nil ? "As the camera sees it" : "As the camera sees it; the simulator's truth dashed")
                : "The sky as seen by eye until Orient Camera"
            if !note.isEmpty {
                ctx.draw(
                    Text(note).font(.system(size: 10)).foregroundColor(grid),
                    at: CGPoint(x: 6, y: size.height - 4), anchor: .bottomLeading)
            }
        }
    }

    // A night sky in either palette, like the sky view: the sunlit part
    // brighter than the dark side; red at night.
    private var sky: Color { model.isNight ? palette.panel : .black }
    private var darkSide: Color { model.isNight ? palette.dim.opacity(0.35) : Color(white: 0.18) }
    private var sunlit: Color { model.isNight ? palette.text.opacity(0.55) : Color(white: 0.55) }
    private var grid: Color { model.isNight ? palette.dim : Color(white: 0.7) }

    private func color(_ id: Int) -> Color {
        switch model.tileStates[id] {
        case .done: (model.isNight ? palette.text : Color(white: 0.9)).opacity(0.45)
        case .moving, .capturing: palette.bright.opacity(0.6)
        case .failed: Color.orange.opacity(0.6)
        default: .clear
        }
    }

    /// Plan pixels to view points, centred on the Moon: the plan (or the
    /// Moon with a margin) and the camera's frame when it is near.
    struct Layout {
        let scale: Double
        let centre: CGPoint
        let moonDiameter: Double

        init?(plan: MosaicPlan?, map: MoonMap?, size: CGSize) {
            let radius: Double
            var span = (x: 0.0, y: 0.0)
            if let plan {
                radius = plan.moonRadiusPixels
                for t in plan.tiles {
                    span.x = max(span.x, abs(t.center.x) + Double(plan.frameWidth) / 2)
                    span.y = max(span.y, abs(t.center.y) + Double(plan.frameHeight) / 2)
                }
            } else if let map {
                radius = map.radiusPx
            } else {
                return nil
            }
            // A steady view: the Moon's neighbourhood (or the plan, if
            // larger). The frame doesn't move the zoom; off the view, an arrow
            // points to it.
            span = (max(span.x, 1.8 * radius), max(span.y, 1.5 * radius))
            scale = min((size.width - 12) / (2 * span.x), (size.height - 12) / (2 * span.y))
            centre = CGPoint(x: size.width / 2, y: size.height / 2)
            moonDiameter = 2 * radius * scale
        }

        func point(_ p: PixelOffset) -> CGPoint {
            CGPoint(x: centre.x + p.x * scale, y: centre.y + p.y * scale)
        }

        func rect(_ tile: Tile, _ plan: MosaicPlan) -> CGRect {
            let (w, h) = (Double(plan.frameWidth) * scale, Double(plan.frameHeight) * scale)
            let c = point(tile.center)
            return CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)
        }
    }
}

struct BigButton: ButtonStyle {
    let palette: Palette

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(configuration.isPressed ? palette.background : palette.text)
            .background(
                RoundedRectangle(cornerRadius: 7).fill(
                    configuration.isPressed ? palette.bright : palette.panel)
            )
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(palette.dim, lineWidth: 1))
            .contentShape(Rectangle())
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow
    let palette: Palette
    @Environment(\.dismiss) private var dismiss
    /// An override waiting for the operator's confirmation.
    @State private var pendingOverride: Double?

    var body: some View {
        Form {
            Section("Sun avoidance (while the Sun is up)") {
                Stepper(
                    "Keep at least \(Int(model.sunMinSeparationDeg))° from the Sun",
                    value: $model.sunMinSeparationDeg, in: 10...90, step: 5)
                Picker(
                    "Sunrise/sunset override (this session only)",
                    selection: Binding(
                        get: { model.sunOverrideDeg ?? -1 },
                        set: { v in
                            let new: Double? = v < 0 ? nil : v
                            if new == nil { model.sunOverrideDeg = nil } else { pendingOverride = new }
                        })
                ) {
                    Text("None").tag(-1.0)
                    Text("Lower to 20°").tag(20.0)
                    Text("Lower to 10°").tag(10.0)
                    Text("Off").tag(0.0)
                }
                Text("Every move the app makes, and the whole search area, keep this far from the Sun while it is up (above −2°); after sunset the check is off by itself. Hand-controller moves can't be refused: the app warns. Cover the spotting scope in daylight.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .confirmationDialog(
                "Override Sun avoidance for this session?",
                isPresented: Binding(get: { pendingOverride != nil }, set: { if !$0 { pendingOverride = nil } })
            ) {
                Button(pendingOverride.map { $0 == 0 ? "Turn it off" : "Lower it to \(Int($0))°" } ?? "Override", role: .destructive) {
                    if let v = pendingOverride { model.sunOverrideDeg = v }
                    pendingOverride = nil
                }
                Button("Cancel", role: .cancel) { pendingOverride = nil }
            } message: {
                Text("The scope could point closer to the Sun. Never look through the eyepiece or the spotting scope near the Sun. This lasts until the app quits.")
            }
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
                Stepper(
                    model.glowArcsec > 0
                        ? String(format: "Glow beyond the limb: %.0f′", model.glowArcsec / 60) : "Glow beyond the limb: none",
                    value: $model.glowArcsec, in: 0...600, step: 60)
                Text("Tiles out this far past the sunlit limb, for the halo in haze (at 4′ it's about 1% of the Moon's brightness). Takes effect at the next Plan.")
                    .font(.caption).foregroundStyle(.secondary)
                Picker("Dark-side tiles", selection: $model.darkTilesMode) {
                    Text("Only when earthshine shows").tag("auto")
                    Text("Always: Start shoots them too").tag("include")
                    Text("Never").tag("omit")
                }
                Text("Takes effect at the next Plan. By day earthshine never shows, so Auto leaves them out.")
                    .font(.caption).foregroundStyle(.secondary)
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
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Picker("Simulator scene", selection: $sim.libraryScene) {
                    ForEach(sim.library, id: \.self) { url in
                        Text(sim.libraryNames[url] ?? url.deletingPathExtension().lastPathComponent).tag(Optional(url))
                    }
                }
                .onChange(of: sim.libraryScene) { if sim.sceneChoice != .library { sim.sceneChoice = .library } }
                .disabled(sim.library.isEmpty)
                if sim.loadingScene { ProgressView().controlSize(.small) }
            }
            if sim.library.isEmpty {
                Button("Choose scene folder…") { sim.chooseLibraryFolder() }
            }
            Text(
                sim.library.isEmpty
                    ? "No scenes yet: choose the folder of Moon images for the simulator."
                    : sim.attached
                    ? sim.sceneNote
                    : (sim.sceneMoment.map { "Connect rehearses at this scene's moment: \($0.time.formatted(date: .abbreviated, time: .shortened))." }
                        ?? "Pick a scene, then Connect.")
            ).font(.system(size: 10)).foregroundStyle(palette.dim).lineLimit(2)
            HStack {
                Text("Speed \(Int(sim.speed))×").monospacedDigit()
                Slider(value: $sim.speed, in: 1...10, step: 1).disabled(!model.simulate).frame(width: 90)
                Spacer()
                Button("Random") { sim.randomize(reachDeg: model.searchReachDeg) }
                    .help("Random scenario")
                Button("More…") { openWindow(id: "simulator") }
            }
        }
        .font(.system(size: 12))
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).stroke(palette.dim.opacity(0.5), lineWidth: 1))
    }
}

/// Where Here puts the Moon, for the wide views: the camera's aim from the
/// Moon's centre as the app reckons it (″, x along azimuth, y up). The
/// estimated Moon is drawn that far back from the camera's frame.
struct SkyEstimate: Equatable {
    let aim: CGPoint
    let radiusArcsec: Double
}
