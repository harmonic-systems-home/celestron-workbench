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
                .frame(minWidth: 1150, minHeight: 640)
                .onAppear { NSApplication.shared.activate() }
        }
        .defaultSize(width: LaptopSize.width, height: LaptopSize.height)
        .commands {
            CommandGroup(after: .windowSize) {
                Button("Laptop Screen Size") { LaptopSize.apply() }
                    .keyboardShortcut("l", modifiers: [.command, .option])
            }
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") { model.showSettings = true }
                    .keyboardShortcut(",", modifiers: .command)
            }
        }
        Window("Simulator", id: "simulator") {
            SimulatorView(model: model, sim: model.simulator)
                .frame(minWidth: 820, minHeight: 560)
        }
        .defaultSize(width: 980, height: 680)
    }
}

/// The field laptop's screen (a 13-inch MacBook Air: 1470 × 956 points,
/// 1470 × 849 left by the menu bar and Dock), which the main window is
/// designed for. Window ▸ Laptop Screen Size (⌥⌘L) sets the window to it
/// on a bigger screen, to lay things out.
enum LaptopSize {
    static let width: CGFloat = 1470
    static let height: CGFloat = 849

    static func apply() {
        guard
            let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.title == "Moon Mosaic" }),
            let screen = window.screen ?? NSScreen.main
        else { return }
        let v = screen.visibleFrame
        // Keep the top-left corner, but on the screen.
        var frame = NSRect(x: window.frame.minX, y: window.frame.maxY - height, width: width, height: height)
        frame.origin.x = min(max(frame.minX, v.minX), max(v.maxX - width, v.minX))
        frame.origin.y = min(max(frame.minY, v.minY), max(v.maxY - height, v.minY))
        window.setFrame(frame, display: true, animate: true)
    }
}
