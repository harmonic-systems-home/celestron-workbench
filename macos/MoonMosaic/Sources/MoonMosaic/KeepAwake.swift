import Foundation

/// Keeps the Mac from idle-sleeping while a session is running, on battery
/// as well as on power: at the telescope a sleeping laptop stops the
/// recording and breaks the serial link. The display can still sleep, and
/// closing the lid still sleeps the Mac.
@MainActor
final class KeepAwake {
    private let reason: String
    private var activity: NSObjectProtocol?

    init(reason: String) { self.reason = reason }

    var isOn: Bool {
        get { activity != nil }
        set {
            if newValue, activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(
                    options: [.idleSystemSleepDisabled], reason: reason)
            } else if !newValue, let a = activity {
                ProcessInfo.processInfo.endActivity(a)
                activity = nil
            }
        }
    }
}
