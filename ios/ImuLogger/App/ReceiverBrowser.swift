import Network
import Observation

/// Finds Mac receivers advertising `_cwb-imu._tcp` on the local network (ADR 0004).
@MainActor @Observable
final class ReceiverBrowser {
    struct Receiver: Identifiable, Hashable {
        let name: String
        let endpoint: NWEndpoint
        var id: String { name }
    }

    private(set) var receivers: [Receiver] = []
    private(set) var problem: String?
    private var browser: NWBrowser?

    func start() {
        guard browser == nil else { return }
        let browser = NWBrowser(for: .bonjour(type: "_cwb-imu._tcp", domain: nil), using: .tcp)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            let found = results.compactMap { result -> Receiver? in
                guard case .service(let name, _, _, _) = result.endpoint else { return nil }
                return Receiver(name: name, endpoint: result.endpoint)
            }
            Task { @MainActor in self?.receivers = found.sorted { $0.name < $1.name } }
        }
        browser.stateUpdateHandler = { [weak self] state in
            let problem: String?
            switch state {
            case .failed(let error), .waiting(let error):
                problem = "Discovery unavailable: \(error.localizedDescription)"
            default:
                problem = nil
            }
            Task { @MainActor in
                self?.problem = problem
                // A failed browser never recovers; start a new one shortly.
                if case .failed = state {
                    try? await Task.sleep(for: .seconds(2))
                    self?.restart()
                }
            }
        }
        browser.start(queue: .main)
        self.browser = browser
    }

    /// Replaces the browser with a fresh one, keeping the current results
    /// until the new browser reports.
    func restart() {
        browser?.cancel()
        browser = nil
        start()
    }
}
