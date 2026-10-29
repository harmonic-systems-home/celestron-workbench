import Foundation
import ImuLoggerCore
import Network
import Observation
import SwiftUI
import UIKit

/// App state: settings, the active session, and live statistics for the UI.
@MainActor @Observable
final class Recorder {
    enum ReceiverChoice: Hashable {
        case none
        case discovered(NWEndpoint)
        case manual
    }

    // MARK: Settings (persisted, locked while recording)

    static let rateOptionsHz: [Double] = [25, 50, 100, 200]

    var requestedRateHz: Double =
        UserDefaults.standard.object(forKey: "requestedRateHz")
        as? Double ?? 100
    {
        didSet { UserDefaults.standard.set(requestedRateHz, forKey: "requestedRateHz") }
    }
    var referenceFrame: AttitudeReferenceFrame =
        AttitudeReferenceFrame(
            rawValue: UserDefaults.standard.string(forKey: "referenceFrame") ?? "")
        ?? .xArbitraryZVertical
    {
        didSet { UserDefaults.standard.set(referenceFrame.rawValue, forKey: "referenceFrame") }
    }
    var recordRawGyro = UserDefaults.standard.object(forKey: "recordRawGyro") as? Bool ?? true {
        didSet { UserDefaults.standard.set(recordRawGyro, forKey: "recordRawGyro") }
    }
    var recordRawAccel = UserDefaults.standard.object(forKey: "recordRawAccel") as? Bool ?? true {
        didSet { UserDefaults.standard.set(recordRawAccel, forKey: "recordRawAccel") }
    }
    var recordRawMagnetometer =
        UserDefaults.standard.object(forKey: "recordRawMagnetometer") as? Bool ?? false
    {
        didSet { UserDefaults.standard.set(recordRawMagnetometer, forKey: "recordRawMagnetometer") }
    }
    /// Where the phone is, as the operator says; recorded with each session.
    var environment: Site.Environment =
        Site.Environment(rawValue: UserDefaults.standard.string(forKey: "environment") ?? "")
        ?? .unspecified
    {
        didSet { UserDefaults.standard.set(environment.rawValue, forKey: "environment") }
    }
    /// Record a location fix with each session (ADR 0012).
    var recordLocation = UserDefaults.standard.object(forKey: "recordLocation") as? Bool ?? true {
        didSet { UserDefaults.standard.set(recordLocation, forKey: "recordLocation") }
    }
    /// Remembered across launches: a discovered receiver by its Bonjour name,
    /// reselected whenever it is advertised again (see `receiversFound`).
    var receiverChoice: ReceiverChoice = Recorder.savedChoice {
        didSet {
            let saved: String
            switch receiverChoice {
            case .none: saved = "none"
            case .manual: saved = "manual"
            case .discovered(let endpoint):
                guard case .service(let name, _, _, _) = endpoint else { return }
                saved = "service:" + name
            }
            UserDefaults.standard.set(saved, forKey: "receiverChoice")
        }
    }

    private static var savedChoice: ReceiverChoice {
        UserDefaults.standard.string(forKey: "receiverChoice") == "manual" ? .manual : .none
    }

    /// Selects the remembered receiver when the browser finds it, unless the
    /// operator has since chosen something else or is recording.
    func receiversFound(_ receivers: [ReceiverBrowser.Receiver]) {
        guard !isRecording, receiverChoice == .none,
            let saved = UserDefaults.standard.string(forKey: "receiverChoice"),
            saved.hasPrefix("service:"),
            let match = receivers.first(where: { "service:" + $0.name == saved })
        else { return }
        receiverChoice = .discovered(match.endpoint)
    }
    var manualHost = UserDefaults.standard.string(forKey: "manualHost") ?? "" {
        didSet { UserDefaults.standard.set(manualHost, forKey: "manualHost") }
    }
    var manualPort = UserDefaults.standard.string(forKey: "manualPort") ?? "47800" {
        didSet { UserDefaults.standard.set(manualPort, forKey: "manualPort") }
    }

    // MARK: Device facts

    let availability = MotionSource.availability()
    let availableFrames = MotionSource.availableFrames()
    let deviceInfo: DeviceInfo

    // MARK: Session state

    struct ActiveSession {
        let id: String
        let startedAt: Date
        let fileURL: URL
        let pipeline: SessionPipeline
        let motion: MotionSource
        let streams: [SensorStream]
    }

    private(set) var session: ActiveSession?
    private(set) var snapshot = SessionPipeline.Snapshot()
    private(set) var lastFinishedFile: URL?
    private(set) var errorMessage: String?
    private(set) var markerCount = 0
    /// The session's site as recorded: accuracy and status, never coordinates.
    private(set) var siteSummary: String?
    private var refreshTask: Task<Void, Never>?
    private var notificationTokens: [NSObjectProtocol] = []

    var isRecording: Bool { session != nil }

    init() {
        deviceInfo = DeviceInfo(
            deviceId: Self.deviceId(), vendor: "Apple", model: Self.modelIdentifier(),
            osVersion: UIDevice.current.systemVersion, appVersion: Self.appVersion(),
            bootId: PhoneClock.bootId)
        if !availableFrames.contains(referenceFrame),
            let first = availableFrames.first
        {
            referenceFrame = first
        }
    }

    var selectedStreams: [SensorStream] {
        var streams: [SensorStream] = []
        if availability.deviceMotion { streams.append(.deviceMotion) }
        if recordRawGyro && availability.gyro { streams.append(.gyro) }
        if recordRawAccel && availability.accel { streams.append(.accel) }
        if recordRawMagnetometer && availability.magnetometer { streams.append(.magnetometer) }
        return streams
    }

    var receiverEndpoint: NWEndpoint? {
        switch receiverChoice {
        case .none: return nil
        case .discovered(let endpoint): return endpoint
        case .manual:
            let host = manualHost.trimmingCharacters(in: .whitespaces)
            guard !host.isEmpty, let port = NWEndpoint.Port(manualPort) else { return nil }
            return .hostPort(host: NWEndpoint.Host(host), port: port)
        }
    }

    // MARK: Actions

    func start() {
        guard session == nil else { return }
        errorMessage = nil
        let id = UUID().uuidString.lowercased()
        let startedAt = Date()
        let url = Self.sessionsDirectory.appendingPathComponent(
            Self.fileName(for: id, at: startedAt))
        let log: SessionLog
        do {
            log = try SessionLog(creating: url)
        } catch {
            errorMessage = "Could not create the session log: \(error.localizedDescription)"
            return
        }
        let streams = selectedStreams
        let hello = Hello(
            protocolVersion: protocolVersion, sessionId: id, device: deviceInfo,
            sensorAvailability: availability, streams: streams,
            attitudeReferenceFrame: referenceFrame, requestedIntervalS: 1 / requestedRateHz,
            accelG0MS2: standardGravity)
        let endpoint = receiverEndpoint
        // Room for several seconds of samples at the requested rate, so only
        // a stalled pipeline drops data.
        let capacity = max(4096, Int(requestedRateHz * Double(streams.count) * 10))
        let pipeline = SessionPipeline(
            sessionId: id, deviceId: deviceInfo.deviceId, bufferCapacity: capacity, log: log
        ) { pipeline in
            endpoint.map { endpoint in
                Uplink(
                    endpoint: endpoint, hello: hello, logURL: url,
                    onClockResult: { [weak pipeline] result in pipeline?.clockResult(result) }
                ) { [weak pipeline] status in
                    pipeline?.uplinkStatusChanged(status)
                }
            }
        }
        pipeline.start(hello: hello)

        let motion = MotionSource()
        motion.start(
            .init(
                interval: 1 / requestedRateHz, referenceFrame: referenceFrame, streams: Set(streams)
            ),
            into: pipeline.buffer
        ) { [weak pipeline] stream, error in
            pipeline?.event(
                .interruption, .error,
                detail: [
                    "stream": .string(stream.rawValue), "error": .string(String(describing: error)),
                ])
        }

        session = ActiveSession(
            id: id, startedAt: startedAt, fileURL: url, pipeline: pipeline, motion: motion,
            streams: streams)
        markerCount = 0
        recordSite(sessionId: id, pipeline: pipeline)
        UIApplication.shared.isIdleTimerDisabled = true
        observeDeviceState(pipeline)
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.refresh()
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func stop() {
        guard let session else { return }
        refreshTask?.cancel()
        refreshTask = nil
        session.motion.stop()
        session.pipeline.finish(reason: .operatorStop)
        snapshot = session.pipeline.snapshot()
        notificationTokens.forEach(NotificationCenter.default.removeObserver)
        notificationTokens.removeAll()
        UIDevice.current.isBatteryMonitoringEnabled = false
        UIApplication.shared.isIdleTimerDisabled = false
        lastFinishedFile = session.fileURL
        self.session = nil
    }

    /// Sends the session's `site` once a fix arrives, or straight away when
    /// location is off. A session stopped first goes without one.
    private func recordSite(sessionId: String, pipeline: SessionPipeline) {
        let environment = environment
        siteSummary = recordLocation ? "Finding location…" : "Location off"
        Task { [weak self, deviceId = deviceInfo.deviceId] in
            var outcome = LocationFixer.Outcome(status: .off, location: nil, precise: false)
            if self?.recordLocation == true {
                outcome = await LocationFixer().fix()
            }
            guard let self, self.session?.id == sessionId else { return }
            let now = Date()
            let location = outcome.location.map {
                Site.Location($0, precise: outcome.precise, now: now)
            }
            let ageNs = Int64((location?.fixAgeS ?? 0) * 1e9)
            pipeline.emit(
                .site(
                    Site(
                        protocolVersion: protocolVersion, sessionId: sessionId, deviceId: deviceId,
                        siteId: UUID().uuidString.lowercased(), tNs: PhoneClock.nowNs() - ageNs,
                        environment: environment, locationStatus: outcome.status,
                        location: location)))
            siteSummary =
                switch outcome.status {
                case .fix:
                    String(
                        format: "Recorded, ±%.0f m%@", location?.horizontalAccuracyM ?? 0,
                        outcome.precise ? "" : " (approximate)")
                case .off: "Location off"
                case .denied: "Location access denied in Settings"
                case .unavailable: "No fix within \(LocationFixer.timeout.components.seconds) s"
                }
        }
    }

    func addMarker(label: String) {
        guard let session else { return }
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        markerCount += 1
        session.pipeline.emit(
            .marker(
                Marker(
                    protocolVersion: protocolVersion, sessionId: session.id,
                    deviceId: deviceInfo.deviceId, markerId: UUID().uuidString.lowercased(),
                    label: trimmed.isEmpty ? "marker \(markerCount)" : trimmed,
                    tNs: PhoneClock.nowNs(), notes: nil)))
    }

    func scenePhaseChanged(to phase: ScenePhase) {
        guard let session else { return }
        let name: String
        switch phase {
        case .active: name = "active"
        case .inactive: name = "inactive"
        case .background: name = "background"
        @unknown default: name = "unknown"
        }
        session.pipeline.event(
            .appState, phase == .active ? .info : .warning, detail: ["state": .string(name)])
    }

    private func refresh() {
        guard let session else { return }
        snapshot = session.pipeline.snapshot()
    }

    private func observeDeviceState(_ pipeline: SessionPipeline) {
        let center = NotificationCenter.default
        let thermal: @MainActor @Sendable () -> Void = { [weak pipeline] in
            let state = ProcessInfo.processInfo.thermalState
            pipeline?.event(
                .thermalState,
                state.rawValue >= ProcessInfo.ThermalState.serious.rawValue
                    ? .warning : .info,
                detail: ["state": .string(state.name)])
        }
        thermal()
        notificationTokens.append(
            center.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
            ) { _ in MainActor.assumeIsolated { thermal() } })

        UIDevice.current.isBatteryMonitoringEnabled = true
        let battery: @MainActor @Sendable () -> Void = { [weak pipeline] in
            let device = UIDevice.current
            pipeline?.event(
                .batteryState,
                detail: [
                    "level": device.batteryLevel < 0 ? .null : .number(Double(device.batteryLevel)),
                    "state": .string(device.batteryState.name),
                ])
        }
        battery()
        for name in [
            UIDevice.batteryStateDidChangeNotification, UIDevice.batteryLevelDidChangeNotification,
        ] {
            notificationTokens.append(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainActor.assumeIsolated { battery() }
                })
        }
    }

    // MARK: Files

    static var sessionsDirectory: URL {
        URL.documentsDirectory.appendingPathComponent("Sessions", isDirectory: true)
    }

    static func fileName(for sessionId: String, at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return "\(formatter.string(from: date))_\(sessionId.prefix(8)).ndjson"
    }

    // MARK: Identity

    /// A random ID generated once per install. Never a hardware identifier.
    private static func deviceId() -> String {
        if let existing = UserDefaults.standard.string(forKey: "deviceId") { return existing }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "deviceId")
        return id
    }

    /// Hardware model identifier such as "iPhone18,2" (not unique to the device).
    private static func modelIdentifier() -> String {
        if let simulated = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulated
        }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }

    private static func appVersion() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(version) (\(build))"
    }
}

extension ProcessInfo.ThermalState {
    var name: String {
        switch self {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

extension UIDevice.BatteryState {
    var name: String {
        switch self {
        case .unplugged: "unplugged"
        case .charging: "charging"
        case .full: "full"
        default: "unknown"
        }
    }
}
