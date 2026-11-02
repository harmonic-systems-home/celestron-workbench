import AppKit
import AuxListenerCore
import SwiftUI

/// Dark red on black at night, so the screen doesn't spoil night vision
/// (ADR 0018); ordinary colours by day. The model sets `isNight`, and the
/// views it drives redraw when it changes.
@MainActor
enum Palette {
    static var isNight = true

    static var background: Color {
        isNight ? .black : Color(nsColor: .windowBackgroundColor)
    }
    static var panel: Color {
        isNight ? Color(red: 0.07, green: 0.0, blue: 0.0) : Color(nsColor: .controlBackgroundColor)
    }
    static var dim: Color { isNight ? Color(red: 0.38, green: 0.04, blue: 0.03) : .secondary }
    static var text: Color { isNight ? Color(red: 0.72, green: 0.1, blue: 0.07) : .primary }
    static var bright: Color { isNight ? Color(red: 1.0, green: 0.28, blue: 0.12) : .orange }
}

struct ContentView: View {
    @ObservedObject var model: ListenerModel
    @State private var settings = false

    var body: some View {
        // Read here so the window redraws when it changes.
        Palette.isNight = model.isNight
        return VStack(spacing: 12) {
            header
            anomalies
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 12) {
                    devices
                    routes
                }
                .frame(width: 380)
                feed
            }
            marks
        }
        .padding(16)
        .background(Palette.background)
        .foregroundStyle(Palette.text)
        .font(.system(size: 18, design: .rounded))
        .preferredColorScheme(model.isNight ? .dark : .light)
        .sheet(isPresented: $settings) { SettingsView(model: model, done: { settings = false }) }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 18) {
            Circle()
                .fill(linkColor)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(linkText).font(.system(size: 24, weight: .semibold, design: .rounded))
                Text(model.recording.map { "Recording \($0)" } ?? "Not recording")
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(Palette.dim)
                if model.link == .waiting {
                    Text(
                        "It listens on the AUX bus through its own cable; the hand controller's USB isn't used."
                    )
                    .font(.system(size: 15, design: .rounded))
                    .foregroundStyle(Palette.dim)
                }
            }
            Spacer()
            stat("\(model.packetsPerSecond)", "packets/s")
            stat(sinceLast, "since last")
            Button {
                settings = true
            } label: {
                Image(systemName: "gearshape").font(.system(size: 26))
            }
            .buttonStyle(BigButton(height: 56, width: 64))
        }
    }

    private var linkText: String {
        switch model.link {
        case .waiting: "No AUX tap cable (FTDI): waiting for it"
        case .connected(let port): "Listening on \(URL(fileURLWithPath: port).lastPathComponent)"
        case .demo: "DEMO traffic (made up, not recorded)"
        case .failed(let why): "Can't open the cable: \(why)"
        }
    }

    private var linkColor: Color {
        switch model.link {
        case .connected: model.packetsPerSecond > 0 ? Palette.text : Palette.dim
        case .demo: Palette.dim
        case .waiting, .failed: Palette.bright
        }
    }

    private var sinceLast: String {
        guard let last = model.lastPacketAt, model.now >= last else { return "–" }
        let s = Double(model.now - last) / 1e9
        return s < 10 ? String(format: "%.1f s", s) : String(format: "%.0f s", s)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(label).font(.system(size: 13, design: .rounded)).foregroundStyle(Palette.dim)
        }
    }

    // MARK: Anomalies

    private var anomalies: some View {
        HStack(spacing: 10) {
            ForEach(AnomalyKind.allCases, id: \.self) { kind in
                let n = model.counts[kind, default: 0]
                let recent =
                    model.lastAnomalyAt[kind].map { $0 + 10_000_000_000 > model.now } ?? false
                VStack(spacing: 2) {
                    Text("\(n)").font(.system(size: 28, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(kind.label).font(.system(size: 14, design: .rounded))
                }
                .frame(maxWidth: .infinity, minHeight: 64)
                .foregroundStyle(n == 0 ? Palette.dim : recent ? Palette.bright : Palette.text)
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(
                        recent ? Palette.dim.opacity(0.5) : Palette.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(recent ? Palette.bright : Palette.dim, lineWidth: recent ? 3 : 1))
            }
            Button("Clear") { model.resetCounts() }
                .buttonStyle(BigButton(height: 64, width: 90))
        }
    }

    // MARK: Devices

    private var devices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Devices").font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.dim)
            if model.devices.isEmpty {
                Text("None heard yet").foregroundStyle(Palette.dim)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.devices) { d in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(d.name).font(
                                    .system(size: 20, weight: .semibold, design: .rounded))
                                Spacer()
                                Text(age(d.at)).font(.system(size: 14, design: .rounded))
                                    .monospacedDigit()
                                    .foregroundStyle(Palette.dim)
                            }
                            Text(d.text).font(.system(size: 14, design: .monospaced))
                                .lineLimit(2)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Palette.panel))
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func age(_ t: UInt64) -> String {
        guard model.now >= t else { return "" }
        let s = Double(model.now - t) / 1e9
        return s < 60 ? String(format: "%.0f s ago", s) : String(format: "%.0f min ago", s / 60)
    }

    // MARK: Routes

    private var routes: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Messages by sender → receiver")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.dim)
                Spacer()
                Button("Reset") { model.resetRoutes() }
                    .buttonStyle(BigButton(height: 36, width: 80))
            }
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(model.routes) { r in
                        HStack {
                            Text(r.text).font(.system(size: 15, design: .rounded))
                            Spacer()
                            Text("\(r.count)")
                                .font(.system(size: 17, weight: .semibold, design: .rounded))
                                .monospacedDigit()
                        }
                    }
                }
                .padding(10)
            }
            .background(RoundedRectangle(cornerRadius: 8).fill(Palette.panel))
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Feed

    private var feed: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bus traffic").font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.dim)
                Spacer()
                Button(model.showPolling ? "Hide polling" : "Show polling") {
                    model.showPolling.toggle()
                }
                .buttonStyle(BigButton(height: 40, width: 150))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(model.feed) { line in
                            (Text(line.time + "  ").foregroundStyle(Palette.dim) + Text(line.text))
                                .font(
                                    .system(
                                        size: 15, weight: weight(line.kind), design: .monospaced)
                                )
                                .foregroundStyle(color(line.kind))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(line.id)
                        }
                    }
                    .padding(10)
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(Palette.panel))
                .onChange(of: model.feed.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func color(_ kind: ListenerModel.FeedLine.Kind) -> Color {
        switch kind {
        case .anomaly, .mark: Palette.bright
        case .polling, .info: Palette.dim
        case .command, .reply: Palette.text
        }
    }

    private func weight(_ kind: ListenerModel.FeedLine.Kind) -> Font.Weight {
        kind == .command || kind == .mark || kind == .anomaly ? .semibold : .regular
    }

    // MARK: Marks

    private var marks: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
            ForEach(ListenerModel.marks, id: \.self) { label in
                Button(label) { model.mark(label) }
                    .buttonStyle(BigButton(height: 70))
            }
        }
    }
}

/// Large, dim buttons that light up while pressed.
struct BigButton: ButtonStyle {
    var height: CGFloat
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .frame(maxWidth: width ?? .infinity, minHeight: height)
            .frame(width: width)
            .foregroundStyle(configuration.isPressed ? Color.black : Palette.text)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(configuration.isPressed ? Palette.bright : Palette.panel)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Palette.dim, lineWidth: 1.5))
            .contentShape(Rectangle())
    }
}

struct SettingsView: View {
    @ObservedObject var model: ListenerModel
    let done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Settings").font(.system(size: 26, weight: .semibold, design: .rounded))
            Toggle("Sound on anomalies", isOn: $model.soundOn)
            Toggle("Show routine position polling in the feed", isOn: $model.showPolling)
            Toggle(
                "Demo traffic while the AUX tap cable isn't connected", isOn: $model.demoWhenIdle)
            Picker("Palette", selection: $model.paletteMode) {
                Text("Auto (red after dusk)").tag("auto")
                Text("Day").tag("day")
                Text("Night (red)").tag("night")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Sessions are saved in")
                Text(model.folder.path).font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Palette.dim)
                Button("Choose folder…") { choose() }
                    .buttonStyle(BigButton(height: 44, width: 200))
            }
            Spacer()
            Button("Done", action: done).buttonStyle(BigButton(height: 56))
        }
        .toggleStyle(.switch)
        .tint(Palette.dim)
        .font(.system(size: 18, design: .rounded))
        .foregroundStyle(Palette.text)
        .padding(24)
        .frame(width: 520, height: 470)
        .preferredColorScheme(model.isNight ? .dark : .light)
        .background(Palette.background)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = model.folder
        if panel.runModal() == .OK, let url = panel.url {
            model.folder = url
        }
    }
}
