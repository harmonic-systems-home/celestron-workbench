// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AuxListener",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AuxListenerCore", targets: ["AuxListenerCore"]),
        .executable(name: "AuxListener", targets: ["AuxListener"]),
    ],
    targets: [
        // Framing, decoding, anomaly detection, the session log and the
        // read-only serial port (ADR 0018). Everything here is tested.
        .target(name: "AuxListenerCore"),
        // The SwiftUI Mac app: night palette, big buttons, no typing.
        .executableTarget(name: "AuxListener", dependencies: ["AuxListenerCore"]),
        .testTarget(name: "AuxListenerCoreTests", dependencies: ["AuxListenerCore"]),
    ]
)
