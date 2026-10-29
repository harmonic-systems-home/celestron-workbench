import CoreLocation
import ImuLoggerCore

/// One location fix for a session (ADR 0012): asks for When In Use access
/// the first time, listens until a fix is accurate enough or time runs out,
/// keeps the most accurate one, and stops. Coordinates go only into the
/// session's `site` message; nothing here logs or displays them.
@MainActor
final class LocationFixer: NSObject, CLLocationManagerDelegate {
    struct Outcome {
        var status: Site.LocationStatus
        var location: CLLocation?
        var precise: Bool
    }

    /// A fix this good ends the search early.
    static let goodEnoughM: CLLocationAccuracy = 10
    static let timeout: Duration = .seconds(20)

    private let manager = CLLocationManager()
    private var best: CLLocation?
    private var continuation: CheckedContinuation<Outcome, Never>?
    private var timeoutTask: Task<Void, Never>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
    }

    func fix() async -> Outcome {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            timeoutTask = Task { [weak self] in
                try? await Task.sleep(for: Self.timeout)
                self?.finish()
            }
            proceed()
        }
    }

    /// Acts on the current authorization; called again when it changes.
    private func proceed() {
        guard continuation != nil else { return }
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            finish()
        default:
            manager.startUpdatingLocation()
        }
    }

    private func finish() {
        guard let continuation else { return }
        self.continuation = nil
        timeoutTask?.cancel()
        manager.stopUpdatingLocation()
        let status: Site.LocationStatus =
            switch manager.authorizationStatus {
            case .denied, .restricted: .denied
            default: best == nil ? .unavailable : .fix
            }
        continuation.resume(
            returning: Outcome(
                status: status, location: status == .fix ? best : nil,
                precise: manager.accuracyAuthorization == .fullAccuracy))
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated { proceed() }
    }

    nonisolated func locationManager(
        _ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]
    ) {
        MainActor.assumeIsolated {
            for location in locations where location.horizontalAccuracy >= 0 {
                if best.map({ location.horizontalAccuracy < $0.horizontalAccuracy }) ?? true {
                    best = location
                }
            }
            if let best, best.horizontalAccuracy <= Self.goodEnoughM { finish() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // Transient failures (no fix yet) are expected; a denial arrives as
        // an authorization change. The timeout ends the search either way.
    }
}

extension Site.Location {
    /// `fixAgeS` is how old the fix was when the session chose it.
    init(_ location: CLLocation, precise: Bool, now: Date = Date()) {
        let vertical = location.verticalAccuracy > 0
        self.init(
            latitude: location.coordinate.latitude, longitude: location.coordinate.longitude,
            horizontalAccuracyM: location.horizontalAccuracy,
            altitudeM: vertical ? location.altitude : nil,
            verticalAccuracyM: vertical ? location.verticalAccuracy : nil, precise: precise,
            fixAgeS: max(0, now.timeIntervalSince(location.timestamp)))
    }
}
