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
/// The Moon is almost always at or near where the search starts, so the rows
/// run **from the start outward**: the start's own row first, then one row up,
/// one down, two up, two down, and so on. There is always a row through the
/// start. That row begins *at* the start, sweeps out to one end, then jumps
/// back across to sweep the other half (that one jump, half a row, is the only
/// ground crossed twice). Every later row begins at the end where the
/// previous one finished, so rows alternate direction with no return pass.
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
    /// The ordered rows, nearest the start first. The start's row comes as
    /// two half-rows, both beginning at the start (azimuth 0).
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

        // Rows at k·spacing for k = 0, +1, −1, +2, −2, …, ±n: an odd count,
        // centred on the start, spaced no more than asked and spanning the
        // full height.
        let n: Int
        if halfHeightDeg <= 1e-9 || 2 * halfHeightDeg <= rowSpacingDeg {
            n = 0
        } else {
            n = Int((halfHeightDeg / rowSpacingDeg - 1e-9).rounded(.up))
        }
        let spacing = n == 0 ? 0 : halfHeightDeg / Double(n)
        var order = [0]
        for k in stride(from: 1, through: n, by: 1) { order += [k, -k] }

        // The start's row, in two halves: out to −W from the start, then
        // (one jump back) out to +W. Later rows run from the end the
        // previous row finished at.
        var rows = [
            Row(altDeg: 0, fromAzDeg: 0, toAzDeg: -halfWidthDeg),
            Row(altDeg: 0, fromAzDeg: 0, toAzDeg: halfWidthDeg),
        ]
        if halfWidthDeg <= 1e-9 { rows = [Row(altDeg: 0, fromAzDeg: 0, toAzDeg: 0)] }
        for k in order.dropFirst() {
            let end = rows.last!.toAzDeg
            rows.append(Row(altDeg: Double(k) * spacing, fromAzDeg: end, toAzDeg: -end))
        }
        self.rows = rows
    }
}
