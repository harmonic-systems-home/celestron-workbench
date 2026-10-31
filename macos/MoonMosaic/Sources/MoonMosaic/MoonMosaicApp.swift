import AppKit
import SwiftUI

@main
struct MoonMosaicApp: App {
    @StateObject private var model = AppModel()

    init() {
        // A normal app with a Dock icon, even when started with `swift run`.
        NSApplication.shared.setActivationPolicy(.regular)
    }

    var body: some Scene {
        WindowGroup("Moon Mosaic") {
            ContentView(model: model)
                .frame(minWidth: 1150, minHeight: 820)
                .onAppear { NSApplication.shared.activate() }
        }
        .defaultSize(width: 1300, height: 860)
    }
}
