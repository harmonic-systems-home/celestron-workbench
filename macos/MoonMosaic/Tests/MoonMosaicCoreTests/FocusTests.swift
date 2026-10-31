import Foundation
import Testing

@testable import MoonMosaicCore

/// The sharpness number falls as the image blurs, and the crop is the
/// frame's middle, pixel for pixel.
@Test func sharpnessFallsAsTheImageBlurs() throws {
    let camera = FakeCamera(width: 600, height: 400, scale: 0.3, rotationDeg: 0)
    let frame = try #require(try camera.frame(timeoutMs: 0))
    let crop = Focus.crop(frame)
    #expect(crop.width == 200 && crop.height == 132)
    #expect(crop.pixels[0] == frame.pixels[134 * 600 + 200])

    var last = Focus.sharpness(crop)
    #expect(last > 0)
    for radius in [1, 2, 4] {
        let s = Focus.sharpness(blur(crop, radius: radius))
        #expect(s < last, "radius \(radius): \(s) not below \(last)")
        last = s
    }
}

/// A box blur, `radius` pixels each way.
private func blur(_ f: Frame, radius: Int) -> Frame {
    var out = [UInt8](repeating: 0, count: f.pixels.count)
    for y in 0..<f.height {
        for x in 0..<f.width {
            var s = 0
            var n = 0
            for j in max(y - radius, 0)...min(y + radius, f.height - 1) {
                for i in max(x - radius, 0)...min(x + radius, f.width - 1) {
                    s += Int(f.pixels[j * f.width + i])
                    n += 1
                }
            }
            out[y * f.width + x] = UInt8(s / n)
        }
    }
    return Frame(width: f.width, height: f.height, pixels: out, time: f.time)
}
