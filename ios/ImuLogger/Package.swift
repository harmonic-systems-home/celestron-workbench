// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ImuLogger",
    platforms: [.iOS(.v18), .macOS(.v15)],
    products: [
        .library(name: "ImuLoggerCore", targets: ["ImuLoggerCore"])
    ],
    targets: [
        // Platform-independent logic: wire protocol, framing, sequencing.
        // The iOS app target (Core Motion, UI) is added in plan Prompt 2.
        .target(name: "ImuLoggerCore"),
        .testTarget(name: "ImuLoggerCoreTests", dependencies: ["ImuLoggerCore"]),
    ]
)
