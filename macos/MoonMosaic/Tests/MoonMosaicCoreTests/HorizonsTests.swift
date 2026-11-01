import Foundation
import Testing

@testable import MoonMosaicCore

/// The Moon from a made-up site (40° N, 100° W, sea level) on 2026 November 1,
/// from JPL Horizons (ssd.jpl.nasa.gov/api/horizons.api, target 301,
/// observer table, CSV): geocentric apparent RA/Dec and distance (centre
/// 500@399, quantities 2 and 20); the site's apparent azimuth and elevation,
/// airless and refracted (centre coord@399, site -100,40,0, quantities 4 and
/// 20, APPARENT AIRLESS and REFRACTED). Low altitudes are where a parallax or
/// refraction error, or one of the wrong sign, shows most.
private struct Row {
    let utc: String
    /// Geocentric: RA (h m s), Dec (° ′ ″), distance (au).
    let ra: (Double, Double, Double)
    let dec: (Double, Double, Double)
    let geoAU: Double
    /// From the site: azimuth, airless and refracted elevation (°).
    let az: Double
    let airless: Double
    let refracted: Double
}

private let rows = [
    Row(
        utc: "2026-11-01T06:00:00Z", ra: (8, 14, 56.75), dec: (22, 5, 50.2), geoAU: 0.00247769649680,
        az: 70.843231, airless: 10.703876, refracted: 10.788560),
    Row(
        utc: "2026-11-01T07:00:00Z", ra: (8, 17, 21.79), dec: (21, 55, 16.9), geoAU: 0.00247855356341,
        az: 79.432180, airless: 21.328117, refracted: 21.370830),
    Row(
        utc: "2026-11-01T12:00:00Z", ra: (8, 29, 20.05), dec: (21, 0, 40.7), geoAU: 0.00248290850848,
        az: 161.692593, airless: 69.872727, refracted: 69.878943),
    Row(
        utc: "2026-11-01T18:00:00Z", ra: (8, 43, 26.80), dec: (19, 51, 21.7), geoAU: 0.00248827304004,
        az: 279.621482, airless: 19.026047, refracted: 19.074212),
    Row(
        utc: "2026-11-01T19:00:00Z", ra: (8, 45, 46.33), dec: (19, 39, 26.0), geoAU: 0.00248918033908,
        az: 288.093751, airless: 8.115448, refracted: 8.224112),
]

private let site = Site(latitudeDeg: 40, longitudeDeg: -100)
private let kmPerAU = 149_597_870.7

private func date(_ utc: String) -> Date { ISO8601DateFormatter().date(from: utc)! }

/// Azimuth difference, wrapped, as an angle on the sky at that altitude.
private func azError(_ a: Double, _ b: Double, altDeg: Double) -> Double {
    var d = (a - b).truncatingRemainder(dividingBy: 360)
    if d > 180 { d -= 360 }
    if d < -180 { d += 360 }
    return abs(d) * cos(altDeg * .pi / 180)
}

/// Parallax alone: Horizons' own geocentric Moon, put at the site by this
/// code, against Horizons' airless view from the site. Within 0.01° (36″),
/// the size of the approximations (sidereal time without nutation, a round
/// Earth; on the first run, 20″ at most); a parallax left out or of the
/// wrong sign is off by up to 1.9°.
@Test(arguments: rows.indices)
func parallaxMatchesHorizons(_ i: Int) {
    let r = rows[i]
    let eq = Equatorial(
        raDeg: 15 * (r.ra.0 + r.ra.1 / 60 + r.ra.2 / 3600),
        decDeg: r.dec.0 + r.dec.1 / 60 + r.dec.2 / 3600)
    let view = Ephemeris.moon(eq, distanceKm: r.geoAU * kmPerAU, at: date(r.utc), from: site)
    let alt = view.horizontal.altDeg - Ephemeris.refractionDeg(r.airless)
    #expect(abs(alt - r.airless) < 0.01, "\(r.utc): altitude \(alt) vs \(r.airless)")
    #expect(
        azError(view.horizontal.azDeg, r.az, altDeg: alt) < 0.01,
        "\(r.utc): azimuth \(view.horizontal.azDeg) vs \(r.az)")
}

/// Refraction alone: Horizons' refracted minus airless elevation, against
/// this code's refraction at the airless altitude: within 0.001° (3.6″);
/// on the first run, 0.1″ at every altitude.
@Test(arguments: rows.indices)
func refractionMatchesHorizons(_ i: Int) {
    let r = rows[i]
    let ours = Ephemeris.refractionDeg(r.airless)
    let theirs = r.refracted - r.airless
    #expect(ours > 0, "refraction lifts the Moon")
    #expect(abs(ours - theirs) < 0.001, "\(r.utc): \(ours) vs \(theirs)")
}

/// End to end, with this code's own Moon (good to 1–2′): within 0.04°
/// (on the first run, 80″ at most).
@Test(arguments: rows.indices)
func theMoonFromTheSiteMatchesHorizons(_ i: Int) {
    let r = rows[i]
    let view = Ephemeris.moon(at: date(r.utc), from: site)
    #expect(
        abs(view.horizontal.altDeg - r.refracted) < 0.04,
        "\(r.utc): altitude \(view.horizontal.altDeg) vs \(r.refracted)")
    #expect(
        azError(view.horizontal.azDeg, r.az, altDeg: r.refracted) < 0.04,
        "\(r.utc): azimuth \(view.horizontal.azDeg) vs \(r.az)")
}
