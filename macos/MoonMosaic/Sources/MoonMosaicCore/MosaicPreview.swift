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
        var images: [Int: [Float]] = [:]
        for tile in plan.tiles {
            let x0 = Int((tile.center.x / 4 - Double(tw) / 2 - minX).rounded())
            let y0 = Int((tile.center.y / 4 - Double(th) / 2 - minY).rounded())
            rects[tile.id] = (x0, y0, tw, th)
            guard let image = stacks[tile.id]?.image(), image.width == tw, image.height == th
            else { continue }
            images[tile.id] = image.pixels
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
            // A dark tile not taken isn't missing: it waits for earthshine.
            default: if tile.lit { missing.append(tile.id) }
            }
        }
        // Soft against its neighbours, in the strips they share: the same
        // part of the Moon in both, so the content (mare or highland, near
        // the terminator or not) cancels (2026-11-20: a whole-tile score
        // flagged 15 tiles whose content was just smooth). A tile with no
        // neighbour to compare falls back to its score against the sunlit
        // tiles' median.
        var ratios: [Int: [Double]] = [:]
        let tiles = plan.tiles.filter { images[$0.id] != nil && sharpness[$0.id] != nil }
        for (i, a) in tiles.enumerated() {
            for b in tiles[(i + 1)...] {
                guard let (ea, eb) = overlapEnergy(a, b, images, tw, th) else { continue }
                ratios[a.id, default: []].append(ea / eb)
                ratios[b.id, default: []].append(eb / ea)
            }
        }
        let litScores = plan.tiles.filter(\.lit).compactMap { sharpness[$0.id] }.sorted()
        let median = litScores.isEmpty ? 0 : litScores[litScores.count / 2]
        var soft: [Int] = []
        for (id, s) in sharpness {
            if let r = ratios[id], !r.isEmpty {
                let m = r.sorted()[r.count / 2]
                if m < softFraction { soft.append(id) }
            } else if plan.tiles.first(where: { $0.id == id })?.lit ?? true, s < softFraction * median {
                soft.append(id)
            }
        }
        soft.sort()
        return MosaicPreview(
            width: width, height: height, pixels: pixels, missing: missing, failed: failed,
            soft: soft, rects: rects)
    }

    /// Gradient energy of two tiles in the strip they share (4× binned,
    /// inset for aiming error), counting only pixels that are Moon in both;
    /// nil when the strip holds too little Moon to judge.
    static func overlapEnergy(
        _ a: Tile, _ b: Tile, _ images: [Int: [Float]], _ tw: Int, _ th: Int
    ) -> (Double, Double)? {
        guard let ia = images[a.id], let ib = images[b.id] else { return nil }
        // b's top-left in a's pixels.
        let dx = Int(((b.center.x - a.center.x) / 4).rounded())
        let dy = Int(((b.center.y - a.center.y) / 4).rounded())
        let inset = 6
        let x0 = max(0, dx) + inset, x1 = min(tw, tw + dx) - inset
        let y0 = max(0, dy) + inset, y1 = min(th, th + dy) - inset
        guard x1 - x0 >= 8, y1 - y0 >= 8 else { return nil }
        var (ea, eb, n) = (0.0, 0.0, 0)
        for y in y0..<y1 {
            for x in x0..<x1 {
                let (bx, by) = (x - dx, y - dy)
                guard bx >= 1, by >= 1, bx < tw - 1, by < th - 1, x >= 1, y >= 1, x < tw - 1, y < th - 1 else { continue }
                let pa = y * tw + x
                let pb = by * tw + bx
                guard ia[pa] > 0.1, ib[pb] > 0.1 else { continue }
                let gax = Double(ia[pa + 1] - ia[pa - 1]), gay = Double(ia[pa + tw] - ia[pa - tw])
                let gbx = Double(ib[pb + 1] - ib[pb - 1]), gby = Double(ib[pb + tw] - ib[pb - tw])
                ea += gax * gax + gay * gay
                eb += gbx * gbx + gby * gby
                n += 1
            }
        }
        guard n >= 200, ea > 0, eb > 0 else { return nil }
        return (ea, eb)
    }
}
