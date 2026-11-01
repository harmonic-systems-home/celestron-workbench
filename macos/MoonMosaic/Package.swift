// swift-tools-version: 6.0
import Foundation
import PackageDescription

// The mount session library, built by scripts/mount-ffi-lib.sh (ADR 0019).
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let library = root.appendingPathComponent("../../rust/target/universal/release").standardized.path

let package = Package(
    name: "MoonMosaic",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MoonMosaicCore", targets: ["MoonMosaicCore"]),
        .executable(name: "MoonMosaic", targets: ["MoonMosaic"]),
        .executable(name: "MoonMosaicSynth", targets: ["MoonMosaicSynth"]),
    ],
    targets: [
        // The Rust adapter's C interface (rust/crates/mount-ffi).
        .systemLibrary(name: "CCwbMount", path: "Sources/CCwbMount"),
        // Mount session, Moon and Sun positions, planning, camera: all tested.
        .target(
            name: "MoonMosaicCore",
            dependencies: ["CCwbMount"],
            linkerSettings: [
                .unsafeFlags(["-L", library]),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        // The SwiftUI app: big buttons, night and day palettes.
        .executableTarget(name: "MoonMosaic", dependencies: ["MoonMosaicCore"]),
        // A synthetic session for testing scripts/moon-process.sh.
        .executableTarget(name: "MoonMosaicSynth", dependencies: ["MoonMosaicCore"]),
        .testTarget(name: "MoonMosaicCoreTests", dependencies: ["MoonMosaicCore"]),
    ]
)
