import MoonMosaicCore
import SwiftUI

/// Where a search is in its pattern (ADR 0022 amendment 7): the planned
/// stops, the ones visited (brighter where the frame was brighter), and the
/// camera's frame now. When simulating, the true Moon is drawn too, so the
/// search can be watched finding it.
struct SearchMap: View {
    @ObservedObject var model: AppModel
    @ObservedObject var sim: SimulatorModel
    let progress: SearchProgress
    /// Where Here puts the Moon (drawn back from the camera's frame by the aim).
    var estimate: SkyEstimate? = nil

    var body: some View {
        Canvas { ctx, size in
            let cosAlt = cos(progress.altitudeDeg * .pi / 180)
            // On the sky, degrees: x = azimuth offset × cos(altitude).
            func sky(_ o: [Double]) -> CGPoint { CGPoint(x: o[0] * cosAlt, y: o[1]) }
            let pts = progress.pattern.map(sky)
            let xs = pts.map(\.x), ys = pts.map(\.y)
            let pad = max(progress.fieldDeg[0], 0.1)
            let (minX, maxX) = ((xs.min() ?? 0) - pad, (xs.max() ?? 0) + pad)
            let (minY, maxY) = ((ys.min() ?? 0) - pad, (ys.max() ?? 0) + pad)
            let k = min(size.width / (maxX - minX), size.height / (maxY - minY))
            let ox = size.width / 2 - k * (minX + maxX) / 2
            let oy = size.height / 2 + k * (minY + maxY) / 2
            func pt(_ p: CGPoint) -> CGPoint { CGPoint(x: ox + k * p.x, y: oy - k * p.y) }

            ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
            // A pattern riding on the Moon is drawn in the Moon's frame: its
            // motion since the start comes off every position.
            var drift = (0.0, 0.0)
            if progress.followsMoon {
                let site = model.sessionSite
                let a = Ephemeris.moon(at: progress.startTime, from: site).horizontal
                let b = Ephemeris.moon(at: model.sessionNow, from: site).horizontal
                var dAz = b.azDeg - a.azDeg
                dAz -= 360 * (dAz / 360).rounded()
                drift = (dAz, b.altDeg - a.altDeg)
            }
            func fromStart(_ p: [Double]) -> CGPoint {
                var dAz = p[0] - progress.start[0]
                dAz -= 360 * (dAz / 360).rounded()
                return sky([dAz - drift.0, p[1] - progress.start[1] - drift.1])
            }
            // Where the mount is now: when simulating, from the same reading
            // as the true Moon, so the two don't jitter against each other.
            var now: CGPoint?
            if sim.attached, let m = sim.mountAxesDeg {
                now = fromStart(m)
            } else if let p = model.positionDeg, p.count == 2 {
                now = fromStart(p)
            }
            // The sky behind, fixed on the axes: dots every 0.5° that drift
            // across as the pattern rides on the Moon, so the sweep shows.
            if progress.followsMoon {
                let g = 0.5
                let span = Int(((maxX - minX) / g).rounded(.up)) + 4
                let i0 = Int(((minX + drift.0 * cosAlt) / g).rounded(.down)) - 2
                let j0 = Int(((minY + drift.1) / g).rounded(.down)) - 2
                for i in i0..<(i0 + span) {
                    for j in j0..<(j0 + span) {
                        let c = pt(CGPoint(x: Double(i) * g - drift.0 * cosAlt, y: Double(j) * g - drift.1))
                        guard c.x > 0, c.y > 0, c.x < size.width, c.y < size.height else { continue }
                        ctx.fill(
                            Path(ellipseIn: CGRect(x: c.x - 1, y: c.y - 1, width: 2, height: 2)),
                            with: .color(Color(white: 0.45)))
                    }
                }
            }
            // The true Moon (simulation only).
            if sim.attached, let moonAxes = sim.moonAxesDeg {
                let r = sim.moonRadiusArcsec / 3600 * k
                let c = pt(fromStart(moonAxes))
                ctx.fill(
                    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                    with: .color(Color(white: 0.18)))
                if let limb = sim.brightLimbDeg, let i = sim.phaseAngleNowDeg {
                    var lit = Path()
                    lit.addLines(
                        Ephemeris.litOutline(brightLimbFromZenithDeg: limb, phaseAngleDeg: i).map {
                            CGPoint(x: c.x + $0.x * r, y: c.y - $0.y * r)
                        })
                    lit.closeSubpath()
                    ctx.fill(lit, with: .color(Color(white: 0.4)))
                }
                ctx.draw(
                    Text("true Moon").font(.system(size: 10)).foregroundColor(.gray), at: CGPoint(x: c.x, y: c.y))
            }
            // The plan in order: a line through the stops, bright blue for
            // the first and fading toward the last. Then visited stops, by
            // how bright the frame was.
            let n = max(pts.count - 1, 1)
            for (i, (a, b)) in zip(pts, pts.dropFirst()).enumerated() {
                let f = 1 - 0.8 * Double(i) / Double(n)
                var seg = Path()
                seg.move(to: pt(a))
                seg.addLine(to: pt(b))
                ctx.stroke(seg, with: .color(Color(red: 0.3 * f, green: 0.6 * f, blue: f)), lineWidth: 1)
            }
            for (i, p) in pts.enumerated() {
                let f = 1 - 0.8 * Double(i) / Double(n)
                let c = pt(p)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4)),
                    with: .color(Color(red: 0.3 * f, green: 0.6 * f, blue: f)))
            }
            for (p, b) in zip(progress.visited, progress.brightness) {
                let c = pt(sky(p))
                let level = 0.25 + 0.75 * min(max(b, 0), 1)
                ctx.fill(
                    Path(ellipseIn: CGRect(x: c.x - 3, y: c.y - 3, width: 6, height: 6)),
                    with: .color(Color(red: level, green: level, blue: 0.2 * level)))
            }
            // The camera's frame now.
            if let now {
                let (w, h) = (progress.fieldDeg[0] * k, progress.fieldDeg[1] * k)
                let c = pt(now)
                ctx.stroke(
                    Path(CGRect(x: c.x - w / 2, y: c.y - h / 2, width: w, height: h)), with: .color(.red),
                    lineWidth: 1.5)
            }
            if let now, let e = estimate {
                let c = pt(CGPoint(x: now.x - e.aim.x / 3600, y: now.y - e.aim.y / 3600))
                let r = e.drawnRadius / 3600 * k
                ctx.stroke(
                    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r)),
                    with: .color(.orange), style: StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                ctx.draw(
                    Text(e.label).font(.system(size: 10)).foregroundColor(.orange),
                    at: CGPoint(x: c.x, y: c.y + r + 2), anchor: .top)
            }
            let label = progress.caption ?? (progress.finished
                ? "Search finished: \(progress.visited.count) of \(progress.pattern.count) stops"
                : "Stop \(progress.visited.count) of \(progress.pattern.count)")
            ctx.draw(
                Text(label).font(.system(size: 11)).foregroundColor(.white), at: CGPoint(x: 6, y: 4),
                anchor: .topLeading)
            // Where the pattern's centre is on the sky now (it rides on the Moon).
            if progress.followsMoon {
                let site = model.sessionSite
                let a = Ephemeris.moon(at: progress.startTime, from: site).horizontal
                ctx.draw(
                    Text(
                        String(
                            format: "centre ≈ az %.2f°, alt %.2f° · moving with the Moon", a.azDeg + drift.0,
                            a.altDeg + drift.1)
                    ).font(.system(size: 10)).foregroundColor(.gray),
                    at: CGPoint(x: 6, y: size.height - 4), anchor: .bottomLeading)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}
