import AppKit
import AuxListenerCore
import Foundation

/// Everything the window shows, driven by the cable (or demo traffic) and a
/// 0.2 s tick. Runs on the main actor; the serial port delivers on the main
/// queue, so reads and ticks never overlap.
@MainActor
final class ListenerModel: ObservableObject {
    static let appVersion = "0.1.0"
    static let marks = [
        "Keypad", "SkySafari", "ASIAIR", "Problem", "Recovered", "Re-plugged USB",
        "Power cycled",
    ]

    enum Link: Equatable {
        case waiting
        case connected(String)
        case demo
        case failed(String)
    }

    struct Device: Identifiable {
        let address: UInt8
        var text: String
        var at: UInt64
        var id: UInt8 { address }
        var name: String { AuxDevice.name(address) }
    }

    struct FeedLine: Identifiable {
        enum Kind { case command, reply, polling, anomaly, mark, info }
        let id: Int
        let at: UInt64
        /// Local wall-clock time, e.g. "21:47:03.512".
        let time: String
        let text: String
        let kind: Kind
    }

    /// Messages from one device to another.
    struct Route: Identifiable {
        let source: UInt8
        let destination: UInt8
        var count: Int
        var id: Int { Int(source) << 8 | Int(destination) }
        var text: String { "\(AuxDevice.name(source)) → \(AuxDevice.name(destination))" }
    }

    @Published private(set) var link: Link = .waiting
    @Published private(set) var recording: String?
    @Published private(set) var packetsPerSecond = 0
    @Published private(set) var lastPacketAt: UInt64?
    @Published private(set) var counts: [AnomalyKind: Int] = [:]
    @Published private(set) var lastAnomalyAt: [AnomalyKind: UInt64] = [:]
    @Published private(set) var devices: [Device] = []
    @Published private(set) var feed: [FeedLine] = []
    /// Busiest first.
    @Published private(set) var routes: [Route] = []
    @Published private(set) var now = monotonicNs()

    @Published var soundOn: Bool { didSet { defaults.set(soundOn, forKey: "soundOn") } }
    @Published var showPolling: Bool { didSet { defaults.set(showPolling, forKey: "showPolling") } }
    @Published var demoWhenIdle: Bool {
        didSet {
            defaults.set(demoWhenIdle, forKey: "demoWhenIdle")
            if !demoWhenIdle, link == .demo { stopDemo() }
        }
    }
    @Published var folder: URL { didSet { defaults.set(folder.path, forKey: "folder") } }

    private let defaults = UserDefaults.standard
    private var framer = Framer()
    private var monitor = BusMonitor()
    private var reader: SerialReader?
    private var log: SessionLog?
    private var demo: DemoTraffic?
    private var timer: Timer?
    private var lastScan: UInt64 = 0
    private var arrivals: [UInt64] = []
    private var lastSound: UInt64 = 0
    private var nextLine = 0

    init() {
        defaults.register(defaults: ["soundOn": true, "showPolling": false, "demoWhenIdle": true])
        soundOn = defaults.bool(forKey: "soundOn")
        showPolling = defaults.bool(forKey: "showPolling")
        demoWhenIdle = defaults.bool(forKey: "demoWhenIdle")
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder =
            defaults.string(forKey: "folder").map { URL(fileURLWithPath: $0) }
            ?? support.appendingPathComponent("AuxListener/sessions")
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    // MARK: - Actions

    func mark(_ label: String) {
        let t = monotonicNs()
        log?.write(LogLine.mark(label, at: t, utc: Date()))
        append(
            "★ \(label)" + (recording == nil && link != .demo ? " (not recording: no cable)" : ""),
            at: t, kind: .mark)
    }

    func resetCounts() {
        counts = [:]
        lastAnomalyAt = [:]
    }

    func resetRoutes() {
        routes = []
    }

    // MARK: - Tick

    private func tick() {
        now = monotonicNs()
        if reader == nil, now - lastScan > 1_000_000_000 {
            lastScan = now
            if let port = serialPorts(vendorID: ftdiVendorID).first {
                connect(port)
            } else if demoWhenIdle, link != .demo {
                startDemo()
            }
        }
        if var d = demo {
            for (bytes, at) in d.advance(to: now) {
                ingest(bytes, at: at)
            }
            demo = d
        }
        handle(framer.flush(at: now).flatMap { monitor.process($0) })
        handle(monitor.expire(at: now))
        arrivals.removeAll { $0 + 1_000_000_000 < now }
        packetsPerSecond = arrivals.count
    }

    // MARK: - Cable

    private func connect(_ port: String) {
        stopDemo()
        do {
            reader = try SerialReader(
                path: port, queue: .main,
                onBytes: { [weak self] bytes, t in
                    MainActor.assumeIsolated { self?.ingest(bytes, at: t) }
                },
                onClose: { [weak self] in
                    MainActor.assumeIsolated { self?.disconnected(port) }
                })
        } catch {
            link = .failed("\(error)")
            return
        }
        link = .connected(port)
        let t = monotonicNs()
        do {
            let log = try SessionLog(folder: folder, start: Date())
            log.write(
                LogLine.session(
                    source: "cable", appVersion: Self.appVersion, at: t, utc: Date()))
            log.write(LogLine.connection("connect", port: port, at: t, utc: Date()))
            self.log = log
            recording = log.url.lastPathComponent
        } catch {
            append("Can't record to \(folder.path): \(error)", at: t, kind: .anomaly)
        }
        append("Listening on \(port)", at: t, kind: .info)
    }

    private func disconnected(_ port: String) {
        let t = monotonicNs()
        log?.write(LogLine.connection("disconnect", port: port, at: t, utc: Date()))
        log?.close()
        log = nil
        recording = nil
        reader = nil
        framer = Framer()
        monitor = BusMonitor()
        link = .waiting
        append("Cable unplugged: waiting for it", at: t, kind: .anomaly)
        alert(at: t)
    }

    // MARK: - Demo

    private func startDemo() {
        guard reader == nil else { return }
        demo = DemoTraffic(start: monotonicNs())
        link = .demo
        append("Demo traffic: made up, not recorded", at: monotonicNs(), kind: .info)
    }

    private func stopDemo() {
        guard demo != nil else { return }
        demo = nil
        framer = Framer()
        monitor = BusMonitor()
        devices = []
        routes = []
        if link == .demo { link = .waiting }
    }

    // MARK: - Bytes to events

    private func ingest(_ bytes: [UInt8], at t: UInt64) {
        handle(framer.feed(bytes, at: t).flatMap { monitor.process($0) })
    }

    private func handle(_ events: [BusEvent]) {
        for event in events {
            switch event {
            case .packet(let p):
                arrivals.append(p.at)
                lastPacketAt = p.at
                log?.write(LogLine.packet(p, utc: utc(p.at)))
                let source = p.packet.source
                if let i = devices.firstIndex(where: { $0.address == source }) {
                    devices[i].text = p.text
                    devices[i].at = p.at
                } else {
                    devices.append(Device(address: source, text: p.text, at: p.at))
                    devices.sort { $0.address < $1.address }
                }
                count(p.packet)
                if showPolling || !p.isPolling {
                    append(
                        p.text, at: p.at,
                        kind: p.isPolling ? .polling : p.isReply ? .reply : .command)
                }
            case .anomaly(let a):
                counts[a.kind, default: 0] += 1
                lastAnomalyAt[a.kind] = a.at
                log?.write(LogLine.anomaly(a, utc: utc(a.at)))
                append("⚠ \(a.detail)", at: a.at, kind: .anomaly)
                alert(at: a.at)
            }
        }
    }

    private func count(_ p: AuxPacket) {
        if let i = routes.firstIndex(where: {
            $0.source == p.source && $0.destination == p.destination
        }) {
            routes[i].count += 1
        } else {
            routes.append(Route(source: p.source, destination: p.destination, count: 1))
        }
        routes.sort { ($0.count, $1.id) > ($1.count, $0.id) }
    }

    private static let clock: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func append(_ text: String, at t: UInt64, kind: FeedLine.Kind) {
        nextLine += 1
        let time = Self.clock.string(from: utc(t))
        feed.append(FeedLine(id: nextLine, at: t, time: time, text: text, kind: kind))
        if feed.count > 400 { feed.removeFirst(feed.count - 400) }
    }

    private func alert(at t: UInt64) {
        guard soundOn, t >= lastSound, t - lastSound > 2_000_000_000 else { return }
        lastSound = t
        NSSound(named: "Funk")?.play()
    }

    /// The wall-clock time of a monotonic time in the recent past.
    private func utc(_ t: UInt64) -> Date {
        let ago = Double(monotonicNs() &- t) / 1e9
        return Date(timeIntervalSinceNow: -max(0, ago))
    }
}
