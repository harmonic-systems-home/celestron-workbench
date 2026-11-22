// Draws Moon Mosaic's app icon: a gibbous Moon with the mosaic plan's
// tiles over it. Synthetic (procedural craters and maria), no photos.
//   swift make-icon.swift out.png [size] [moon.png]
// With moon.png (a square crop, the disk 1/1.05 of its side), that photo is
// the Moon and the tiles cover its sunlit part; without, a drawn Moon.
import AppKit
import CoreGraphics

let args = CommandLine.arguments
let out = args.count > 1 ? args[1] : "icon.png"
let S = args.count > 2 ? Double(args[2])! : 1024
let s = S / 1024
/// The photo, brightened (×1.6, gamma 0.85) so it reads at icon size.
let photo: CGImage? = args.count > 3 ? brighten(
    CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: args[3]) as CFURL, nil)!, 0, nil)!) : nil
func brighten(_ img: CGImage) -> CGImage {
    let w = img.width, h = img.height
    let g = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    g.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    let p = g.data!.bindMemory(to: UInt8.self, capacity: w * h)
    for i in 0..<(w * h) { p[i] = UInt8(min(255, 255 * pow(Double(p[i]) / 255 * 1.6, 0.85))) }
    return g.makeImage()!
}
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: 0,
    space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }

// Background: macOS icon grid (824 of 1024, rounded), night sky.
let inset = 100 * s, side = 824 * s
let bg = CGRect(x: inset, y: inset, width: side, height: side)
let bgPath = CGPath(roundedRect: bg, cornerWidth: 185 * s, cornerHeight: 185 * s, transform: nil)
ctx.saveGState()
ctx.addPath(bgPath); ctx.clip()
let sky = CGGradient(colorsSpace: cs, colors: [rgb(0.05, 0.06, 0.12), rgb(0.01, 0.01, 0.03)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(sky, start: CGPoint(x: 0, y: bg.maxY), end: CGPoint(x: 0, y: bg.minY), options: [])
var rng = SystemRandomNumberGenerator()
struct LCG { var x: UInt64; mutating func next() -> Double { x = x &* 6364136223846793005 &+ 1442695040888963407; return Double(x >> 11) / Double(1 << 53) } }
var r = LCG(x: 42)
for _ in 0..<60 {  // a few stars
    let p = CGPoint(x: bg.minX + r.next() * side, y: bg.minY + r.next() * side)
    let a = 0.3 + 0.6 * r.next(), d = (1 + 2 * r.next()) * s
    ctx.setFillColor(rgb(1, 1, 1, a)); ctx.fillEllipse(in: CGRect(x: p.x, y: p.y, width: d, height: d))
}

// The Moon: a disk with maria and craters, lit from the right (gibbous).
let c = CGPoint(x: 512 * s, y: 512 * s), R = 300 * s
let disk = CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)
var litMask: [UInt8]? = nil
if let photo {
    let big = CGRect(x: c.x - 1.05 * R, y: c.y - 1.05 * R, width: 2.1 * R, height: 2.1 * R)
    ctx.saveGState()
    ctx.addEllipse(in: disk.insetBy(dx: -2 * s, dy: -2 * s)); ctx.clip()
    ctx.interpolationQuality = .high
    ctx.draw(photo, in: big)
    ctx.restoreGState()
    // The photo's brightness at icon scale, for which tiles are sunlit.
    var m = [UInt8](repeating: 0, count: Int(S) * Int(S))
    let g = CGContext(data: &m, width: Int(S), height: Int(S), bitsPerComponent: 8, bytesPerRow: Int(S),
        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0)!
    g.draw(photo, in: big)
    litMask = m
} else {
ctx.saveGState()
ctx.addEllipse(in: disk); ctx.clip()
let body = CGGradient(colorsSpace: cs, colors: [rgb(0.93, 0.92, 0.88), rgb(0.70, 0.69, 0.66)] as CFArray, locations: [0, 1])!
ctx.drawRadialGradient(body, startCenter: CGPoint(x: c.x + 0.3 * R, y: c.y + 0.3 * R), startRadius: 0, endCenter: c, endRadius: R * 1.1, options: [.drawsAfterEndLocation])
// Maria: soft dark blobs, roughly where the nearside's are.
let maria: [(Double, Double, Double)] = [(-0.35, 0.35, 0.30), (-0.05, 0.42, 0.22), (0.2, 0.25, 0.2), (0.3, -0.05, 0.18), (-0.45, -0.05, 0.25), (-0.15, 0.05, 0.16), (0.05, -0.35, 0.14), (0.42, 0.42, 0.12)]
for m in maria {
    let p = CGPoint(x: c.x + m.0 * R, y: c.y + m.1 * R), rr = m.2 * R
    let g = CGGradient(colorsSpace: cs, colors: [rgb(0.42, 0.42, 0.42, 0.75), rgb(0.42, 0.42, 0.42, 0)] as CFArray, locations: [0.4, 1])!
    ctx.drawRadialGradient(g, startCenter: p, startRadius: 0, endCenter: p, endRadius: rr, options: [])
}
for _ in 0..<28 {  // craters: a dark rim on the shadow side, a bright one sunward
    let a = r.next() * 2 * .pi, d = sqrt(r.next()) * 0.95 * R
    let p = CGPoint(x: c.x + cos(a) * d, y: c.y + sin(a) * d)
    let cr = (4 + 22 * pow(r.next(), 2.5)) * s
    ctx.setFillColor(rgb(0.35, 0.35, 0.35, 0.22))
    ctx.fillEllipse(in: CGRect(x: p.x - cr, y: p.y - cr, width: 2 * cr, height: 2 * cr))
    ctx.setFillColor(rgb(1, 1, 1, 0.18))
    ctx.fillEllipse(in: CGRect(x: p.x - cr * 0.7 + cr * 0.25, y: p.y - cr * 0.7, width: 1.4 * cr, height: 1.4 * cr))
}
// The terminator: night side on the left, softened.
let term = CGMutablePath()
term.move(to: CGPoint(x: c.x, y: c.y + R))
term.addArc(center: c, radius: R, startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
term.addCurve(to: CGPoint(x: c.x, y: c.y + R), control1: CGPoint(x: c.x - 0.55 * R * 1.33, y: c.y - R), control2: CGPoint(x: c.x - 0.55 * R * 1.33, y: c.y + R))
ctx.setShadow(offset: .zero, blur: 18 * s, color: rgb(0, 0, 0, 1))
ctx.addPath(term); ctx.setFillColor(rgb(0.02, 0.02, 0.05, 0.93)); ctx.fillPath()
ctx.restoreGState()

}
// The plan: overlapping tiles over the sunlit part, in the app's red.
let cols = 4, rows = 5
let step = (x: 2.16 * R / Double(cols), y: 2.16 * R / Double(rows))
let tw = step.x / 0.88, th = step.y / 0.88
let red = rgb(1.0, 0.27, 0.22)
ctx.setLineWidth(6 * s)
ctx.setLineJoin(.round)
func lit(_ p: CGPoint) -> Bool {
    if let m = litMask {
        let x = Int(p.x), y = Int(S) - 1 - Int(p.y)  // the buffer runs top-down
        guard x >= 0, y >= 0, x < Int(S), y < Int(S) else { return false }
        return m[y * Int(S) + x] > 40
    }
    let dx = (p.x - c.x) / R, dy = (p.y - c.y) / R
    return hypot(dx, dy) < 1 && dx > -0.55 * sqrt(max(0, 1 - dy * dy))
}
for j in 0..<rows {
    for i in 0..<cols {
        let mid = CGPoint(x: c.x + (Double(i) - Double(cols - 1) / 2) * step.x, y: c.y + (Double(j) - Double(rows - 1) / 2) * step.y)
        let tile = CGRect(x: mid.x - tw / 2, y: mid.y - th / 2, width: tw, height: th)
        var any = false
        for u in stride(from: 0.0, through: 1.0, by: 0.25) { for v in stride(from: 0.0, through: 1.0, by: 0.25) {
            if lit(CGPoint(x: tile.minX + u * tw, y: tile.minY + v * th)) { any = true } } }
        if any { ctx.setStrokeColor(red); ctx.stroke(tile) }
    }
}
ctx.restoreGState()
// A faint edge on the tile.
ctx.addPath(bgPath); ctx.setStrokeColor(rgb(1, 1, 1, 0.08)); ctx.setLineWidth(2 * s); ctx.strokePath()

let img = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: img)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
