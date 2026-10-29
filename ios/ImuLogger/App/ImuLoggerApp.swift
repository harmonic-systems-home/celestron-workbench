import SwiftUI

@main
struct ImuLoggerApp: App {
    @State private var recorder = Recorder()
    @State private var browser = ReceiverBrowser()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(recorder)
                .environment(browser)
                .onAppear { browser.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            recorder.scenePhaseChanged(to: phase)
            // A browser left running while suspended can stop reporting results.
            if phase == .active { browser.restart() }
        }
    }
}
