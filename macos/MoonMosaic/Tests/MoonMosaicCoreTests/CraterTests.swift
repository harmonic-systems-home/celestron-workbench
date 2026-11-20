import Foundation
import Testing

@testable import MoonMosaicCore

/// The crater catalogue placed on tonight's disk agrees with the phase: at
/// first quarter the Crisium side (lunar east) is lit and Grimaldi (far
/// lunar west) is dark, and the reverse at last quarter; the Sun's height
/// over each crater has the sign `isLit` gives its place.
@Suite struct CraterTests {
    let site = Site(latitudeDeg: 40, longitudeDeg: -100)

    func quarter(waxing: Bool) -> Date {
        var t = Date(timeIntervalSince1970: 1_793_491_200)
        for _ in 0..<(24 * 40) {
            let p = Ephemeris.phase(at: t, from: site)
            let later = Ephemeris.phase(at: t.addingTimeInterval(3600 * 12), from: site)
            if abs(p.phaseAngleDeg - 90) < 3, (later.illuminatedFraction > p.illuminatedFraction) == waxing { return t }
            t.addTimeInterval(3600)
        }
        return t
    }

    @Test func firstQuarterLightsTheEast() {
        let t = quarter(waxing: true)
        let lang = Craters.place(Craters.catalogue.first { $0.name == "Langrenus" }!, at: t, from: site)
        let grim = Craters.place(Craters.catalogue.first { $0.name == "Grimaldi" }!, at: t, from: site)
        #expect(lang.sunAltitudeDeg > 20, "Langrenus \(lang.sunAltitudeDeg)")
        #expect(grim.sunAltitudeDeg < -20, "Grimaldi \(grim.sunAltitudeDeg)")
    }

    @Test func lastQuarterLightsTheWest() {
        let t = quarter(waxing: false)
        let lang = Craters.place(Craters.catalogue.first { $0.name == "Langrenus" }!, at: t, from: site)
        let grim = Craters.place(Craters.catalogue.first { $0.name == "Grimaldi" }!, at: t, from: site)
        #expect(lang.sunAltitudeDeg < -20 && grim.sunAltitudeDeg > 20)
    }

    @Test func sunHeightAgreesWithIsLit() {
        for days in stride(from: 1.0, to: 28, by: 2.3) {
            let t = Date(timeIntervalSince1970: 1_793_491_200 + days * 86_400)
            let phase = Ephemeris.phase(at: t, from: site)
            for c in Craters.catalogue {
                let p = Craters.place(c, at: t, from: site)
                guard p.visible, abs(p.sunAltitudeDeg) > 3 else { continue }
                #expect(phase.isLit(p.x, p.y) == (p.sunAltitudeDeg > 0), "\(c.name) day \(days)")
            }
        }
    }
}
