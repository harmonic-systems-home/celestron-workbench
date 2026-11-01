import Foundation

/// An offset on the sky, in arcseconds: `x` along azimuth as seen on the sky
/// (Δazimuth × cos altitude), `y` along altitude.
public struct SkyOffset: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A shift in the image, in pixels: x right, y down.
public struct PixelOffset: Sendable, Equatable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// How the image moves when the pointing moves relative to the Moon
/// (ADR 0019): a 2×2 matrix in pixels per arcsecond, measured from two
/// calibration moves, so the camera can sit at any angle and either way up.
public struct CameraCalibration: Sendable, Equatable {
    /// image = [[a, b], [c, d]] · sky
    public let a: Double
    public let b: Double
    public let c: Double
    public let d: Double

    public init(a: Double, b: Double, c: Double, d: Double) {
        (self.a, self.b, self.c, self.d) = (a, b, c, d)
    }

    /// From two moves: each the change in pointing relative to the Moon
    /// (the mount's move minus the Moon's own motion meanwhile) and the image
    /// shift it caused. The moves must not be parallel.
    public init?(
        _ m1: (sky: SkyOffset, image: PixelOffset), _ m2: (sky: SkyOffset, image: PixelOffset)
    ) {
        // P = M S, so M = P S⁻¹.
        let det = m1.sky.x * m2.sky.y - m2.sky.x * m1.sky.y
        guard abs(det) > 1e-6 else { return nil }
        let (s11, s12, s21, s22) = (
            m2.sky.y / det, -m2.sky.x / det, -m1.sky.y / det, m1.sky.x / det
        )
        a = m1.image.x * s11 + m2.image.x * s21
        b = m1.image.x * s12 + m2.image.x * s22
        c = m1.image.y * s11 + m2.image.y * s21
        d = m1.image.y * s12 + m2.image.y * s22
    }

    public var arcsecPerPixel: Double { 1 / abs(a * d - b * c).squareRoot() }

    /// How far the camera is turned (degrees), for display: 0 when its
    /// rows run along azimuth with altitude up. The image moves against the
    /// pointing, and image rows count downwards, hence the signs.
    public var rotationDeg: Double { atan2(b, -a) * 180 / .pi }

    public func image(for sky: SkyOffset) -> PixelOffset {
        PixelOffset(x: a * sky.x + b * sky.y, y: c * sky.x + d * sky.y)
    }

    public func sky(for image: PixelOffset) -> SkyOffset {
        let det = a * d - b * c
        return SkyOffset(
            x: (d * image.x - b * image.y) / det, y: (-c * image.x + a * image.y) / det)
    }
}

/// One tile of the mosaic.
public struct Tile: Sendable, Equatable, Identifiable {
    public let id: Int
    public let row: Int
    public let column: Int
    /// Where the tile's centre is, in pixels from the Moon's centre, in the
    /// camera's frame as it was when calibrated.
    public let center: PixelOffset
    /// The pointing, relative to the Moon's centre, that puts the tile in view.
    public let pointing: SkyOffset
}

public struct MosaicPlan: Sendable, Equatable {
    public let tiles: [Tile]
    public let overlap: Double
    public let moonRadiusPixels: Double
    public let frameWidth: Int
    public let frameHeight: Int
}

public enum MosaicPlanner {
    /// A grid in the camera's own frame covering the Moon's disk (plus
    /// `margin` of its radius), tiles overlapping by `overlap` of the frame,
    /// tiles that miss the disk dropped, in serpentine order.
    public static func plan(
        moonDiameterDeg: Double, calibration: CameraCalibration, frameWidth: Int, frameHeight: Int,
        overlap: Double = 0.25, margin: Double = 0.03
    ) -> MosaicPlan {
        let (w, h) = (Double(frameWidth), Double(frameHeight))
        let radius = moonDiameterDeg / 2 * 3600 / calibration.arcsecPerPixel
        let reach = radius * (1 + margin)
        let (sx, sy) = (w * (1 - overlap), h * (1 - overlap))
        // Each tile's own share of the grid is its step, sx × sy, around its
        // centre; the shares fit together without gaps, so the tiles whose
        // shares reach the Moon cover it, and the overlap beyond each share
        // takes up aiming error. Enough steps each way to pass the limb.
        let nx = Int(((reach - sx / 2) / sx).rounded(.up))
        let ny = Int(((reach - sy / 2) / sy).rounded(.up))
        var tiles: [Tile] = []
        for (r, j) in (-ny...ny).enumerated() {
            let columns = Array(-nx...nx)
            for i in r.isMultiple(of: 2) ? columns : columns.reversed() {
                let center = PixelOffset(x: Double(i) * sx, y: Double(j) * sy)
                // The share's nearest point to the Moon's centre.
                let nearX = max(abs(center.x) - sx / 2, 0)
                let nearY = max(abs(center.y) - sy / 2, 0)
                guard nearX * nearX + nearY * nearY < reach * reach else { continue }
                // To bring this part of the Moon to the frame's centre, the
                // image must move by minus its position.
                let pointing = calibration.sky(for: PixelOffset(x: -center.x, y: -center.y))
                tiles.append(
                    Tile(
                        id: tiles.count, row: r, column: i + nx, center: center, pointing: pointing)
                )
            }
        }
        return MosaicPlan(
            tiles: tiles, overlap: overlap, moonRadiusPixels: radius, frameWidth: frameWidth,
            frameHeight: frameHeight)
    }

    /// The mount's move, in its own axes (degrees), that turns a sky offset
    /// at the Moon's altitude.
    public static func axes(for sky: SkyOffset, altitudeDeg: Double) -> (
        azDeg: Double, altDeg: Double
    ) {
        (sky.x / 3600 / cos(altitudeDeg * .pi / 180), sky.y / 3600)
    }
}
