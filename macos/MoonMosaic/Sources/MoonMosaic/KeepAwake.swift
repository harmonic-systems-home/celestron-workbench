import Foundation

/// Keeps the Mac from idle-sleeping while a session is running, on battery
/// as well as on power: at the telescope a sleeping laptop stops the
/// recording and breaks the serial link. The display stays on too: the
/// operator watches the live view and the preview from the mount, and a dark
/// screen read as a sleeping Mac on 2026-11-19. Closing the lid still sleeps
/// the Mac.
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
                    options: [.idleSystemSleepDisabled, .idleDisplaySleepDisabled], reason: reason)
            } else if !newValue, let a = activity {
                ProcessInfo.processInfo.endActivity(a)
                activity = nil
            }
        }
    }
}
