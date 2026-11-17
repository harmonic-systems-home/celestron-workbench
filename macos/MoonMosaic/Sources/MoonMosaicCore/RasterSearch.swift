import Foundation

/// A serpentine (boustrophedon) raster over a rectangle of sky, for a fast,
/// wide automated search (ADR 0022). Where `SpiralSearch` steps and shoots,
/// the raster **sweeps each row** at a moderate rate and grabs frames as fast
/// as the camera allows: fewer, longer moves cover a wide area quickly, which
/// beats a spiral's many short gotos when the uncertainty is large.
///
/// Rows run along **azimuth** (the sweep axis) and are stacked in **altitude**
/// by about `rowSpacingDeg`. Set the spacing below the target's *detectable*
/// width, which can be **wider than the camera's field** — the Moon's glow
/// shows in frame before its disk does — so no gap between rows can hide it.
/// Rows alternate direction, so the drive goes to the first row's near end,
/// sweeps to the far end, steps up one row, sweeps back, and so on — no wasted
/// return travel.
///
/// Offsets are from where the search started, in mount-axis degrees.
public struct RasterSearch: Sendable, Equatable {
    /// One row: a constant altitude, swept in azimuth from `fromAzDeg` to
    /// `toAzDeg` (the sign gives the sweep direction).
    public struct Row: Sendable, Equatable {
        public let altDeg: Double
        public let fromAzDeg: Double
        public let toAzDeg: Double

        public init(altDeg: Double, fromAzDeg: Double, toAzDeg: Double) {
            self.altDeg = altDeg
            self.fromAzDeg = fromAzDeg
            self.toAzDeg = toAzDeg
        }
    }

    public let halfWidthDeg: Double
    public let halfHeightDeg: Double
    /// The requested row spacing; the actual spacing is this or a little less,
    /// so the rows span the full height evenly.
    public let rowSpacingDeg: Double
    public let rows: [Row]

    /// `halfWidthDeg`/`halfHeightDeg`: half the azimuth/altitude extent to
    /// cover, centred on the start. `rowSpacingDeg`: the most altitude between
    /// rows.
    public init(halfWidthDeg: Double, halfHeightDeg: Double, rowSpacingDeg: Double) {
        precondition(
            halfWidthDeg >= 0 && halfHeightDeg >= 0 && rowSpacingDeg > 0,
            "extents must be non-negative and row spacing positive")
        self.halfWidthDeg = halfWidthDeg
        self.halfHeightDeg = halfHeightDeg
        self.rowSpacingDeg = rowSpacingDeg

        let count: Int
        let spacing: Double
        if halfHeightDeg <= 1e-9 || 2 * halfHeightDeg <= rowSpacingDeg {
            count = 1
            spacing = 0
        } else {
            count = Int((2 * halfHeightDeg / rowSpacingDeg).rounded(.up)) + 1
            spacing = 2 * halfHeightDeg / Double(count - 1)
        }

        var rows: [Row] = []
        for i in 0..<count {
            let alt = count == 1 ? 0 : -halfHeightDeg + Double(i) * spacing
            let leftToRight = i % 2 == 0
            rows.append(
                Row(
                    altDeg: alt,
                    fromAzDeg: leftToRight ? -halfWidthDeg : halfWidthDeg,
                    toAzDeg: leftToRight ? halfWidthDeg : -halfWidthDeg))
        }
        self.rows = rows
    }
}
