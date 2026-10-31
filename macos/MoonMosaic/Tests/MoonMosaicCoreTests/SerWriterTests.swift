import Foundation
import Testing

@testable import MoonMosaicCore

@Test func serFilesHaveTheHeaderFramesAndTimestamps() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
        "moonmosaic-\(UUID().uuidString).ser")
    defer { try? FileManager.default.removeItem(at: url) }
    let start = Date(timeIntervalSince1970: 1_800_000_000)
    let writer = try SerWriter(
        url: url, width: 4, height: 2, colorID: 8, instrument: "ZWO ASI662MC",
        telescope: "EdgeHD 8", start: start)
    for i in 0..<3 {
        try writer.append(
            Frame(
                width: 4, height: 2, pixels: [UInt8](repeating: UInt8(i), count: 8),
                time: start.addingTimeInterval(Double(i) / 10)))
    }
    try writer.finish()

    let data = try Data(contentsOf: url)
    #expect(data.count == 178 + 3 * 8 + 3 * 8)
    #expect(String(decoding: data.prefix(14), as: UTF8.self) == "LUCAM-RECORDER")
    let int32 = { (at: Int) in
        data.subdata(in: at..<(at + 4)).withUnsafeBytes { $0.load(as: Int32.self) }
    }
    #expect(int32(18) == 8)  // colour: RGGB
    #expect(int32(26) == 4 && int32(30) == 2 && int32(34) == 8)
    #expect(int32(38) == 3)  // frame count
    #expect(String(decoding: data[82..<94], as: UTF8.self) == "ZWO ASI662MC")
    #expect(data[178 + 8] == 1)  // second frame's first pixel
    let lastTime = data.suffix(8).withUnsafeBytes { $0.loadUnaligned(as: Int64.self) }
    #expect(lastTime == SerWriter.ticks(start.addingTimeInterval(0.2), local: false))
}

@Test func zwoBayerPatternsMapToSerColourIDs() {
    let colour = { (p: Int) in
        CameraInfo(name: "", width: 1, height: 1, pixelSizeUm: 1, isColor: true, bayerPattern: p)
    }
    #expect([0, 1, 2, 3].map { SerWriter.colorID(for: colour($0)) } == [8, 11, 9, 10])
    let mono = CameraInfo(
        name: "", width: 1, height: 1, pixelSizeUm: 1, isColor: false, bayerPattern: 0)
    #expect(SerWriter.colorID(for: mono) == 0)
}
