import AppKit
import SwiftUI

@main
struct AuxListenerApp: App {
    @StateObject private var model = ListenerModel()

    init() {
        // Run as a normal app with a Dock icon, even when started with `swift run`.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("AUX Listener") {
            ContentView(model: model)
                .frame(minWidth: 1100, minHeight: 720)
                .onAppear { NSApplication.shared.activate() }
        }
        .defaultSize(width: 1280, height: 820)
    }
}
