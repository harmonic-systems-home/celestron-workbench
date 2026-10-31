import AppKit
import AuxListenerCore
import SwiftUI

/// Dark red on black, so the screen doesn't spoil night vision (ADR 0018).
enum Night {
    static let background = Color.black
    static let panel = Color(red: 0.07, green: 0.0, blue: 0.0)
    static let dim = Color(red: 0.38, green: 0.04, blue: 0.03)
    static let text = Color(red: 0.72, green: 0.1, blue: 0.07)
    static let bright = Color(red: 1.0, green: 0.28, blue: 0.12)
}

struct ContentView: View {
    @ObservedObject var model: ListenerModel
    @State private var settings = false

    var body: some View {
        VStack(spacing: 12) {
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
        .background(Night.background)
        .foregroundStyle(Night.text)
        .font(.system(size: 18, design: .rounded))
        .preferredColorScheme(.dark)
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
                    .foregroundStyle(Night.dim)
            }
            Spacer()
            stat("\(model.packetsPerSecond)", "packets/s")
            stat(sinceLast, "since last")
            Button {
                settings = true
            } label: {
                Image(systemName: "gearshape").font(.system(size: 26))
            }
            .buttonStyle(NightButton(height: 56, width: 64))
        }
    }

    private var linkText: String {
        switch model.link {
        case .waiting: "No cable: waiting for it"
        case .connected(let port): "Listening on \(URL(fileURLWithPath: port).lastPathComponent)"
        case .demo: "DEMO traffic (made up, not recorded)"
        case .failed(let why): "Can't open the cable: \(why)"
        }
    }

    private var linkColor: Color {
        switch model.link {
        case .connected: model.packetsPerSecond > 0 ? Night.text : Night.dim
        case .demo: Night.dim
        case .waiting, .failed: Night.bright
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
            Text(label).font(.system(size: 13, design: .rounded)).foregroundStyle(Night.dim)
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
                .foregroundStyle(n == 0 ? Night.dim : recent ? Night.bright : Night.text)
                .background(
                    RoundedRectangle(cornerRadius: 10).fill(
                        recent ? Night.dim.opacity(0.5) : Night.panel)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(recent ? Night.bright : Night.dim, lineWidth: recent ? 3 : 1))
            }
            Button("Clear") { model.resetCounts() }
                .buttonStyle(NightButton(height: 64, width: 90))
        }
    }

    // MARK: Devices

    private var devices: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Devices").font(.system(size: 15, weight: .semibold, design: .rounded))
                .foregroundStyle(Night.dim)
            if model.devices.isEmpty {
                Text("None heard yet").foregroundStyle(Night.dim)
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
                                    .foregroundStyle(Night.dim)
                            }
                            Text(d.text).font(.system(size: 14, design: .monospaced))
                                .lineLimit(2)
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Night.panel))
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
                    .foregroundStyle(Night.dim)
                Spacer()
                Button("Reset") { model.resetRoutes() }
                    .buttonStyle(NightButton(height: 36, width: 80))
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
            .background(RoundedRectangle(cornerRadius: 8).fill(Night.panel))
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    // MARK: Feed

    private var feed: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Bus traffic").font(.system(size: 15, weight: .semibold, design: .rounded))
                    .foregroundStyle(Night.dim)
                Spacer()
                Button(model.showPolling ? "Hide polling" : "Show polling") {
                    model.showPolling.toggle()
                }
                .buttonStyle(NightButton(height: 40, width: 150))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(model.feed) { line in
                            (Text(line.time + "  ").foregroundStyle(Night.dim) + Text(line.text))
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
                .background(RoundedRectangle(cornerRadius: 8).fill(Night.panel))
                .onChange(of: model.feed.last?.id) { _, id in
                    if let id { proxy.scrollTo(id, anchor: .bottom) }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func color(_ kind: ListenerModel.FeedLine.Kind) -> Color {
        switch kind {
        case .anomaly, .mark: Night.bright
        case .polling, .info: Night.dim
        case .command, .reply: Night.text
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
                    .buttonStyle(NightButton(height: 70))
            }
        }
    }
}

/// Large, dim buttons that light up while pressed.
struct NightButton: ButtonStyle {
    var height: CGFloat
    var width: CGFloat?

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .semibold, design: .rounded))
            .frame(maxWidth: width ?? .infinity, minHeight: height)
            .frame(width: width)
            .foregroundStyle(configuration.isPressed ? Color.black : Night.text)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(configuration.isPressed ? Night.bright : Night.panel)
            )
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Night.dim, lineWidth: 1.5))
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
            Toggle("Demo traffic while no cable is connected", isOn: $model.demoWhenIdle)
            VStack(alignment: .leading, spacing: 6) {
                Text("Sessions are saved in")
                Text(model.folder.path).font(.system(size: 14, design: .monospaced))
                    .foregroundStyle(Night.dim)
                Button("Choose folder…") { choose() }
                    .buttonStyle(NightButton(height: 44, width: 200))
            }
            Spacer()
            Button("Done", action: done).buttonStyle(NightButton(height: 56))
        }
        .toggleStyle(.switch)
        .tint(Night.dim)
        .font(.system(size: 18, design: .rounded))
        .foregroundStyle(Night.text)
        .padding(24)
        .frame(width: 520, height: 420)
        .background(Night.background)
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
