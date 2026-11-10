import Foundation
import Testing

@testable import MoonMosaicCore

// Kept identical in AuxListenerCoreTests and MoonMosaicCoreTests, but for the import.

private let t0 = Date(timeIntervalSince1970: 1_794_000_000)

private func samples(
    _ gauge: inout BatteryGauge, from: Double, to: Double, minutes: Int, charging: Bool
) {
    for m in 0...minutes {
        let v = from + (to - from) * Double(m) / Double(minutes)
        gauge.add(.init(at: t0.addingTimeInterval(Double(m) * 60), volts: v, charging: charging))
    }
}

@Test func percentFollowsTheLifepo4CurveForThreeCells() {
    #expect(BatteryGauge.percent(volts: 10.20) == 100)
    #expect(BatteryGauge.percent(volts: 12.0) == 100)
    #expect(BatteryGauge.percent(volts: 7.0) == 0)
    // 3.25 V a cell is 40%: where the mount's own level fell from 2 to 1.
    #expect(abs(BatteryGauge.percent(volts: 9.75) - 40) < 1e-9)
    var last = -1.0
    for v in stride(from: 7.5, through: 10.2, by: 0.01) {
        let p = BatteryGauge.percent(volts: v)
        #expect(p >= last)
        last = p
    }
}

@Test func onBatteryItProjectsTimeLeftFromTheRecentRate() {
    var g = BatteryGauge()
    // 70% → 60% (9.90 V → 9.81 V) in an hour: about 6 h left.
    samples(&g, from: 9.90, to: 9.81, minutes: 60, charging: false)
    let h = try! #require(g.hoursLeft)
    #expect(abs(h - 6) < 0.01)
    #expect(g.hoursToFull == nil)
    #expect(g.summary == "~60%, about 6 h left")
    #expect(g.headline?.value == "~60%" && g.headline?.detail == "about 6 h left")
}

@Test func noProjectionUntilTheReadingsSpanTenMinutes() {
    var g = BatteryGauge()
    samples(&g, from: 9.90, to: 9.85, minutes: 5, charging: false)
    #expect(g.hoursLeft == nil)
    // 9.85 V is about 64%, shown to the nearest 10.
    #expect(g.summary == "~60%")
}

@Test func aSteadyChargeGivesNoTimeLeft() {
    var g = BatteryGauge()
    samples(&g, from: 9.80, to: 9.80, minutes: 30, charging: false)
    #expect(g.hoursLeft == nil)
}

@Test func onTheChargerItProjectsTimeToFullWithoutAPercentage() {
    var g = BatteryGauge()
    // +0.2 V an hour, 0.6 V short of 10.8 V: about 3 h.
    samples(&g, from: 10.0, to: 10.2, minutes: 60, charging: true)
    let h = try! #require(g.hoursToFull)
    #expect(abs(h - 3) < 0.01)
    #expect(g.hoursLeft == nil)
    #expect(g.summary == "Charging, 10.20 V, full in about 3 h (rough)")
    #expect(g.headline?.value == "Charging")
    #expect(g.headline?.detail == "10.20 V, full in about 3 h (rough)")
}

@Test func unpluggingTheChargerStartsAfresh() {
    var g = BatteryGauge()
    samples(&g, from: 10.0, to: 10.2, minutes: 60, charging: true)
    g.add(.init(at: t0.addingTimeInterval(61 * 60), volts: 10.1, charging: false))
    #expect(g.latest?.charging == false)
    #expect(g.hoursLeft == nil && g.hoursToFull == nil)
}

@Test func durationsRoundSensibly() {
    #expect(BatteryGauge.duration(hours: 0.75) == "45 min")
    #expect(BatteryGauge.duration(hours: 3.33) == "3 h 20 min")
    #expect(BatteryGauge.duration(hours: 2.0) == "2 h")
}
