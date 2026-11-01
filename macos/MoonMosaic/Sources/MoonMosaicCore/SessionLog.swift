import Foundation

/// The session's record for processing (ADR 0019): `session.ndjson` beside
/// the SER files, one JSON object per line: the plan (with the calibration),
/// then a line for each tile captured or failed. scripts/moon-process.sh
/// seeds the stitch from it. No site coordinates are written.
public final class SessionLog {
    public static let fileName = "session.ndjson"

    public let url: URL
    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(
                date.formatted(.iso8601.year().month().day().time(includingFractionalSeconds: true))
            )
        }
        return e
    }()

    public init(folder: URL) {
        url = folder.appendingPathComponent(Self.fileName)
    }

    public struct XY: Encodable, Sendable {
        public let x: Double
        public let y: Double
    }

    public struct PlanRecord: Encodable {
        let type = "plan"
        let time: Date
        let frameWidth: Int
        let frameHeight: Int
        /// The SER colour ID: 0 mono, 8–11 a Bayer pattern.
        let colorID: Int32
        let overlap: Double
        let moonDiameterDeg: Double
        let moonRadiusPixels: Double
        /// Pixels per arcsecond: image = [[a, b], [c, d]] · sky.
        let calibration: [String: Double]
        let tiles: [PlannedTile]
    }

    public struct PlannedTile: Encodable {
        let id: Int
        let row: Int
        let column: Int
        /// The part of the Moon at the tile's centre, in the camera's pixels
        /// from the Moon's centre (x right, y down).
        let center: XY
        /// Where the camera is aimed, arcseconds from the Moon's centre.
        let pointing: XY
    }

    public struct TileRecord: Encodable {
        let type = "tile"
        let id: Int
        let state: String
        let file: String?
        let frames: Int?
        let sharpness: Double?
        let reason: String?
        let start: Date?
        let end: Date?
        /// The mount's axis angles during the video (it doesn't track).
        let positionDeg: [Double]?
        /// The part of the Moon at the frame's centre halfway through the
        /// video, from the encoders and the Moon's motion, in the camera's
        /// pixels from the Moon's centre.
        let measured: XY?
    }

    public func plan(
        _ plan: MosaicPlan, calibration c: CameraCalibration, moonDiameterDeg: Double,
        colorID: Int32, time: Date
    ) throws {
        try append(
            PlanRecord(
                time: time, frameWidth: plan.frameWidth, frameHeight: plan.frameHeight,
                colorID: colorID, overlap: plan.overlap, moonDiameterDeg: moonDiameterDeg,
                moonRadiusPixels: plan.moonRadiusPixels,
                calibration: [
                    "a": c.a, "b": c.b, "c": c.c, "d": c.d,
                    "arcsecPerPixel": c.arcsecPerPixel, "rotationDeg": c.rotationDeg,
                ],
                tiles: plan.tiles.map {
                    PlannedTile(
                        id: $0.id, row: $0.row, column: $0.column,
                        center: XY(x: $0.center.x, y: $0.center.y),
                        pointing: XY(x: $0.pointing.x, y: $0.pointing.y))
                }))
    }

    public func done(
        _ id: Int, file: String, frames: Int, sharpness: Double, start: Date, end: Date,
        positionDeg: [Double]?, measured: PixelOffset?
    ) throws {
        try append(
            TileRecord(
                id: id, state: "done", file: file, frames: frames, sharpness: sharpness,
                reason: nil, start: start, end: end, positionDeg: positionDeg,
                measured: measured.map { XY(x: $0.x, y: $0.y) }))
    }

    public func failed(_ id: Int, reason: String) throws {
        try append(
            TileRecord(
                id: id, state: "failed", file: nil, frames: nil, sharpness: nil, reason: reason,
                start: nil, end: nil, positionDeg: nil, measured: nil))
    }

    private func append(_ record: some Encodable) throws {
        var line = try encoder.encode(record)
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: line)
    }
}
