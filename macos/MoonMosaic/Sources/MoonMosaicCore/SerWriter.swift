import Foundation

/// Writes a SER video (the planetary-imaging format AutoStakkert,
/// Planetary System Stacker and Siril read): a 178-byte header, 8-bit
/// frames, then each frame's UTC time. The frame count in the header is
/// filled in when the file is finished.
public final class SerWriter {
    public let url: URL
    private let handle: FileHandle
    private let width: Int
    private let height: Int
    private var times: [Date] = []

    /// `colorID`: 0 mono, or the Bayer pattern (8 RGGB, 9 GRBG, 10 GBRG, 11 BGGR).
    public init(
        url: URL, width: Int, height: Int, colorID: Int32, instrument: String, telescope: String,
        start: Date
    ) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        self.url = url
        self.width = width
        self.height = height
        var h = Data()
        h.append(contentsOf: Array("LUCAM-RECORDER".utf8))
        h.append(le: Int32(0))  // LuID
        h.append(le: colorID)
        h.append(le: Int32(0))  // little-endian 16-bit data (unused at 8 bits)
        h.append(le: Int32(width))
        h.append(le: Int32(height))
        h.append(le: Int32(8))  // bits per pixel
        h.append(le: Int32(0))  // frame count, filled in by finish()
        h.append(fixed: "", 40)  // observer
        h.append(fixed: instrument, 40)
        h.append(fixed: telescope, 40)
        h.append(le: Self.ticks(start, local: true))
        h.append(le: Self.ticks(start, local: false))
        precondition(h.count == 178)
        try handle.write(contentsOf: h)
    }

    /// The ZWO Bayer pattern (0 RG, 1 BG, 2 GR, 3 GB) as a SER colour ID.
    public static func colorID(for info: CameraInfo) -> Int32 {
        guard info.isColor else { return 0 }
        return [8, 11, 9, 10][min(max(info.bayerPattern, 0), 3)]
    }

    public func append(_ frame: Frame) throws {
        precondition(frame.width == width && frame.height == height, "frame size changed")
        try handle.write(contentsOf: frame.pixels)
        times.append(frame.time)
    }

    public var frameCount: Int { times.count }

    /// Writes the timestamps and the frame count, and closes the file.
    public func finish() throws {
        var trailer = Data()
        for t in times { trailer.append(le: Self.ticks(t, local: false)) }
        try handle.write(contentsOf: trailer)
        try handle.seek(toOffset: 38)
        try handle.write(
            contentsOf: withUnsafeBytes(of: Int32(times.count).littleEndian) { Data($0) })
        try handle.close()
    }

    /// 100 ns ticks since 0001-01-01, as SER stores times.
    static func ticks(_ date: Date, local: Bool) -> Int64 {
        let offset = local ? Double(TimeZone.current.secondsFromGMT(for: date)) : 0
        return Int64(((date.timeIntervalSince1970 + offset) + 62_135_596_800) * 10_000_000)
    }
}

extension Data {
    fileprivate mutating func append<T: FixedWidthInteger>(le value: T) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    fileprivate mutating func append(fixed text: String, _ length: Int) {
        var bytes = Array(text.utf8.prefix(length))
        bytes += [UInt8](repeating: 0, count: length - bytes.count)
        append(contentsOf: bytes)
    }
}
