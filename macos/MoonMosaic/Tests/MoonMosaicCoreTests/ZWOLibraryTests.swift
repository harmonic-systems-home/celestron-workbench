import Foundation
import Testing

@testable import MoonMosaicCore

/// Reads the connected cameras' details through ZWO's library, without
/// opening any camera. Skipped where no build of the library loads (on
/// Apple silicon, ASIStudio's Intel-only copy doesn't).
@Test(.enabled(if: ZWOLibrary.isAvailable))
func zwoLibraryLoadsAndReadsCameraDetails() throws {
    let library = try ZWOLibrary()
    #expect(!library.sdkVersion.isEmpty)
    for (id, info) in library.cameras() {
        print("camera \(id): \(info)")
        #expect(info.name.hasPrefix("ZWO"))
        #expect(info.width > 0 && info.height > 0)
        #expect(info.pixelSizeUm > 1 && info.pixelSizeUm < 20)
    }
}
