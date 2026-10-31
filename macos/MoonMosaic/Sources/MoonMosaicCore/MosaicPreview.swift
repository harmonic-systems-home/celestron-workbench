import Foundation

/// The field check (ADR 0019): each tile's quick stack placed at its planned
/// position (4× binned), overlaps feathered, and tiles flagged that need
/// another go.
public struct MosaicPreview: Sendable {
    public let width: Int
    public let height: Int
    /// 0–1 brightness, row by row.
    public let pixels: [Float]
    /// Tiles not captured, failed, or much softer than the rest.
    public let missing: [Int]
    public let failed: [Int]
    public let soft: [Int]
    /// Each tile's rectangle in the preview (x, y, width, height), for drawing.
    public let rects: [Int: (x: Int, y: Int, w: Int, h: Int)]

    public static func make(
        plan: MosaicPlan, stacks: [Int: QuickStack], states: [Int: TileState],
        softFraction: Double = 0.6
    ) -> MosaicPreview {
        let (tw, th) = (plan.frameWidth / 4, plan.frameHeight / 4)
        let xs = plan.tiles.map { $0.center.x / 4 }
        let ys = plan.tiles.map { $0.center.y / 4 }
        let minX = (xs.min() ?? 0) - Double(tw) / 2
        let minY = (ys.min() ?? 0) - Double(th) / 2
        let width = Int(((xs.max() ?? 0) + Double(tw) / 2 - minX).rounded(.up))
        let height = Int(((ys.max() ?? 0) + Double(th) / 2 - minY).rounded(.up))
        var sum = [Float](repeating: 0, count: max(width * height, 1))
        var weight = [Float](repeating: 0, count: max(width * height, 1))
        var rects: [Int: (x: Int, y: Int, w: Int, h: Int)] = [:]
        // Feathering: weight falls to zero at a tile's edges.
        let feather = { (i: Int, n: Int) -> Float in
            let d = Float(min(i, n - 1 - i)) / Float(max(n / 6, 1))
            return min(1, max(0.02, d))
        }
        for tile in plan.tiles {
            let x0 = Int((tile.center.x / 4 - Double(tw) / 2 - minX).rounded())
            let y0 = Int((tile.center.y / 4 - Double(th) / 2 - minY).rounded())
            rects[tile.id] = (x0, y0, tw, th)
            guard let image = stacks[tile.id]?.image(), image.width == tw, image.height == th
            else { continue }
            for y in 0..<th {
                let py = y0 + y
                guard py >= 0, py < height else { continue }
                for x in 0..<tw {
                    let px = x0 + x
                    guard px >= 0, px < width else { continue }
                    let w = feather(x, tw) * feather(y, th)
                    sum[py * width + px] += image.pixels[y * tw + x] * w
                    weight[py * width + px] += w
                }
            }
        }
        let pixels = zip(sum, weight).map { $1 > 0 ? $0 / $1 : 0 }
        var missing: [Int] = []
        var failed: [Int] = []
        var sharpness: [Int: Double] = [:]
        for tile in plan.tiles {
            switch states[tile.id] {
            case .done(_, _, let s): sharpness[tile.id] = s
            case .failed: failed.append(tile.id)
            default: missing.append(tile.id)
            }
        }
        let sorted = sharpness.values.sorted()
        let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
        let soft = sharpness.filter { $0.value < softFraction * median }.keys.sorted()
        return MosaicPreview(
            width: width, height: height, pixels: pixels, missing: missing, failed: failed,
            soft: soft, rects: rects)
    }
}
