import Foundation
import Testing

@testable import MoonMosaicCore

// MARK: - Synthetic frames

/// A frame with a bright disk (value `bright`) on a dim sky (`sky`).
private func disk(
    width: Int = 320, height: Int = 240, cx: Double, cy: Double, r: Double,
    bright: UInt8 = 240, sky: UInt8 = 8
) -> Frame {
    var px = [UInt8](repeating: sky, count: width * height)
    for y in 0..<height {
        for x in 0..<width where hypot(Double(x) - cx, Double(y) - cy) <= r {
            px[y * width + x] = bright
        }
    }
    return Frame(width: width, height: height, pixels: px, time: Date())
}

/// A box blur, `radius` pixels each way — spreads edges without moving the
/// centroid.
private func blur(_ f: Frame, radius: Int) -> Frame {
    var out = [UInt8](repeating: 0, count: f.pixels.count)
    for y in 0..<f.height {
        for x in 0..<f.width {
            var sum = 0
            var n = 0
            for dy in -radius...radius {
                for dx in -radius...radius {
                    let yy = y + dy
                    let xx = x + dx
                    guard yy >= 0, yy < f.height, xx >= 0, xx < f.width else { continue }
                    sum += Int(f.pixels[yy * f.width + xx])
                    n += 1
                }
            }
            out[y * f.width + x] = UInt8(sum / max(n, 1))
        }
    }
    return Frame(width: f.width, height: f.height, pixels: out, time: f.time)
}

// MARK: - SpiralSearch

@Test func theSpiralStartsWhereItIsAndWalksOutInSingleAxisSteps() {
    let s = SpiralSearch(stepDeg: 0.1, reachDeg: 0.35)

    // First stop is the start: no move.
    #expect(s.steps.first == SpiralSearch.Step(azDeg: 0, altDeg: 0, axis: .azimuth, deltaDeg: 0))

    // Every later stop is exactly one step on one axis from the one before,
    // and matches its own axis/delta — so each is a single relative goto.
    for i in 1..<s.steps.count {
        let a = s.steps[i - 1]
        let b = s.steps[i]
        #expect(abs(abs(b.deltaDeg) - 0.1) < 1e-9)
        switch b.axis {
        case .azimuth:
            #expect(abs((b.azDeg - a.azDeg) - b.deltaDeg) < 1e-9)
            #expect(abs(b.altDeg - a.altDeg) < 1e-9)
        case .altitude:
            #expect(abs((b.altDeg - a.altDeg) - b.deltaDeg) < 1e-9)
            #expect(abs(b.azDeg - a.azDeg) < 1e-9)
        }
    }
}

@Test func theSpiralStaysInReachVisitsDistinctStopsAndCoversTheBox() {
    let s = SpiralSearch(stepDeg: 0.1, reachDeg: 0.3)
    #expect(s.steps.count > 1)

    var seen = Set<String>()
    var maxReach = 0.0
    for step in s.steps {
        #expect(max(abs(step.azDeg), abs(step.altDeg)) <= 0.3 + 1e-9)
        let key = "\(Int((step.azDeg * 100).rounded())),\(Int((step.altDeg * 100).rounded()))"
        #expect(!seen.contains(key), "stop \(key) visited twice")
        seen.insert(key)
        maxReach = max(maxReach, max(abs(step.azDeg), abs(step.altDeg)))
    }
    // A 0.1 step reaching 0.3 covers a 7×7 grid of stops.
    #expect(s.steps.count == 49)
    #expect(abs(maxReach - 0.3) < 1e-9)
}

@Test func aReachBelowOneStepIsJustTheStart() {
    let s = SpiralSearch(stepDeg: 0.2, reachDeg: 0.0)
    #expect(s.steps.count == 1)
    #expect(s.steps[0].deltaDeg == 0)
}

// MARK: - RasterSearch

@Test func theRasterCoversTheBoxInAlternatingRows() {
    let r = RasterSearch(halfWidthDeg: 1.0, halfHeightDeg: 0.6, rowSpacingDeg: 0.2)
    #expect(r.rows.count >= 2)

    // Rows span the full height, centred on the start, spaced no more than asked.
    #expect(abs(r.rows.first!.altDeg + 0.6) < 1e-9)
    #expect(abs(r.rows.last!.altDeg - 0.6) < 1e-9)
    for i in 1..<r.rows.count {
        let d = r.rows[i].altDeg - r.rows[i - 1].altDeg
        #expect(d > 0 && d <= 0.2 + 1e-9)
    }

    // Each row sweeps the full width, and the path is serpentine: a row
    // starts where the previous one ended (no wasted return travel).
    for (i, row) in r.rows.enumerated() {
        #expect(abs(abs(row.fromAzDeg) - 1.0) < 1e-9 && abs(abs(row.toAzDeg) - 1.0) < 1e-9)
        #expect(row.fromAzDeg != row.toAzDeg)
        if i > 0 { #expect(abs(row.fromAzDeg - r.rows[i - 1].toAzDeg) < 1e-9) }
    }
}

@Test func aShortRegionIsASingleRow() {
    let r = RasterSearch(halfWidthDeg: 1.5, halfHeightDeg: 0.05, rowSpacingDeg: 0.2)
    #expect(r.rows.count == 1)
    #expect(r.rows[0].altDeg == 0)
    #expect(r.rows[0].fromAzDeg == -1.5 && r.rows[0].toAzDeg == 1.5)
}

// MARK: - Blob

@Test func theBlobFindsTheBrightDiskCentreOffCentre() {
    let f = disk(cx: 220, cy: 100, r: 30)  // frame centre is (160, 120)
    let found = try! #require(Blob.find(f))
    #expect(abs(found.x - 220) < 1.0)
    #expect(abs(found.y - 100) < 1.0)
    #expect(abs(found.offsetFromCentre.x - 60) < 1.0)  // 220 - 160
    #expect(abs(found.offsetFromCentre.y + 20) < 1.0)  // 100 - 120
    #expect(found.peak >= 200)
    #expect(found.brightFraction > 0 && found.brightFraction < 0.2)
}

@Test func theBlobCentreSurvivesDefocus() {
    let sharp = disk(cx: 160, cy: 120, r: 28)
    let soft = blur(sharp, radius: 6)
    let a = try! #require(Blob.find(sharp))
    let b = try! #require(Blob.find(soft))
    // An out-of-focus Moon has the same centroid: that is why acquisition,
    // orientation and tracking can run before focus is set.
    #expect(hypot(a.x - b.x, a.y - b.y) < 1.5)
}

@Test func aDarkFrameHasNoBlob() {
    let dark = Frame(
        width: 64, height: 64, pixels: [UInt8](repeating: 6, count: 64 * 64), time: Date())
    #expect(Blob.find(dark) == nil)
}

// MARK: - FocusAssist

@Test func focusScoreFallsWithBlurAndTracksBest() {
    let fa = FocusAssist(settleThresholdPx: 1.5, settleWindow: 2)
    let sharp = disk(cx: 160, cy: 120, r: 40)
    let s1 = fa.add(sharp)
    let s2 = fa.add(blur(sharp, radius: 4))
    #expect(s2.sharpness < s1.sharpness)
    #expect(fa.history.count == 2)
}

@Test func focusTrustsOnlySettledFramesForBest() {
    let fa = FocusAssist(settleThresholdPx: 1.5, settleWindow: 2)
    let sharp = disk(cx: 160, cy: 120, r: 40)
    let soft = blur(sharp, radius: 5)

    // Hand on the knob: the blob jumps around (and the image is shaken/soft).
    _ = fa.add(disk(cx: 150, cy: 120, r: 40))
    _ = fa.add(disk(cx: 172, cy: 108, r: 40))
    let shaking = fa.add(disk(cx: 158, cy: 131, r: 40))
    #expect(shaking.settled == false)

    // Hand off: the blob holds still across frames — settles.
    _ = fa.add(soft)
    _ = fa.add(soft)
    let settledSoft = fa.add(soft)
    #expect(settledSoft.settled == true)

    // A steady sharp frame should then win settledBest over the settled soft one.
    _ = fa.add(sharp)
    _ = fa.add(sharp)
    let settledSharp = fa.add(sharp)
    #expect(settledSharp.settled == true)
    #expect(fa.settledBest?.sharpness == settledSharp.sharpness)
}
