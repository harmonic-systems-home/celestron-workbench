import Foundation
import Testing

@testable import MoonMosaicCore

/// A date from a Julian day.
private func date(jd: Double) -> Date {
    Date(timeIntervalSince1970: (jd - 2_440_587.5) * 86_400)
}

private func near(_ a: Double, _ b: Double, _ tolerance: Double) -> Bool {
    abs(a - b) <= tolerance
}

/// Meeus, Astronomical Algorithms, example 12.a: 1987 April 10, 0h UT.
@Test func siderealTimeMatchesMeeus() {
    let gmst = Ephemeris.gmstDeg(2_446_895.5)
    // 13h 10m 46.3668s
    #expect(near(gmst, 197.693195, 0.000_01), "\(gmst)")
}

/// Meeus example 25.a: 1992 October 13, 0h TD. The low-precision Sun is
/// good to about 0.01°.
@Test func sunMatchesMeeus() {
    let sun = Ephemeris.sun(at: date(jd: 2_448_908.5))
    #expect(near(sun.raDeg, 198.38083, 0.02), "\(sun)")
    #expect(near(sun.decDeg, -7.78507, 0.02), "\(sun)")
}

/// Meeus example 47.a: 1992 April 12, 0h TD: λ 133.162655°, β −3.229126°,
/// Δ 368409.7 km, α 134.688470°, δ 13.768368°. This method is good to 1–2′.
@Test func moonMatchesMeeus() {
    let d = Ephemeris.day(2_448_724.5)
    let (lon, lat, r) = Ephemeris.moonEcliptic(d)
    #expect(near(lon, 133.162655, 0.05), "λ \(lon)")
    #expect(near(lat, -3.229126, 0.05), "β \(lat)")
    // Two distance terms leave about 0.1% (here 327 km): about 3″ of
    // parallax and 0.1% of the Moon's apparent size, both negligible.
    #expect(near(r * Ephemeris.earthRadiusKm, 368_409.7, 500), "Δ \(r * Ephemeris.earthRadiusKm)")
    let (eq, _) = Ephemeris.moon(at: date(jd: 2_448_724.5))
    #expect(near(eq.raDeg, 134.688470, 0.05), "α \(eq.raDeg)")
    #expect(near(eq.decDeg, 13.768368, 0.05), "δ \(eq.decDeg)")
}

/// The Moon moves about 13.2° a day against the stars.
@Test func theMoonsMotionIsAboutThirteenDegreesADay() {
    let t0 = date(jd: 2_461_345.5)
    let (a, _) = Ephemeris.moon(at: t0)
    let (b, _) = Ephemeris.moon(at: t0.addingTimeInterval(86_400))
    let moved = Ephemeris.separationDeg(a, b)
    #expect(moved > 11.5 && moved < 15.5, "\(moved)")
}

/// Parallax lowers the Moon by about its horizontal parallax (≈ 0.95°) near
/// the horizon and by nothing at the zenith; refraction lifts it near the
/// horizon by about half a degree.
@Test func parallaxAndRefractionHaveTheRightSize() {
    #expect(near(Ephemeris.refractionDeg(0), 0.48, 0.05))
    #expect(Ephemeris.refractionDeg(45) < 0.02)
    let site = Site(latitudeDeg: 40, longitudeDeg: -100)
    // Search a day for a moment with the Moon low and one with it high.
    let start = date(jd: 2_461_345.5)
    var low: (geo: Double, topo: Double)?
    var high: (geo: Double, topo: Double)?
    for minute in stride(from: 0, to: 1_440, by: 10) {
        let t = start.addingTimeInterval(Double(minute) * 60)
        let (eq, _) = Ephemeris.moon(at: t)
        let geo = Ephemeris.horizontal(eq, at: t, from: site).altDeg
        let view = Ephemeris.moon(at: t, from: site)
        let topo = view.horizontal.altDeg - Ephemeris.refractionDeg(view.horizontal.altDeg)
        if geo > 2, geo < 8, low == nil { low = (geo, topo) }
        if geo > 40, high == nil || geo > high!.geo { high = (geo, topo) }
        #expect(view.diameterDeg > 0.48 && view.diameterDeg < 0.58, "\(view.diameterDeg)")
    }
    let l = try! #require(low)
    #expect(near(l.geo - l.topo, 0.95, 0.07), "low: \(l)")
    if let h = high {
        #expect(h.geo - h.topo < l.geo - l.topo, "high: \(h)")
    }
}

@Test func separationIsAnAngle() {
    let a = Equatorial(raDeg: 10, decDeg: 0)
    let b = Equatorial(raDeg: 100, decDeg: 0)
    #expect(near(Ephemeris.separationDeg(a, b), 90, 1e-9))
    #expect(near(Ephemeris.separationDeg(a, a), 0, 1e-6))
}
