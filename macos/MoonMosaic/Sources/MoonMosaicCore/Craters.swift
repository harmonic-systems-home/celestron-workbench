import Foundation

/// Go to [crater] (ADR 0022 amendment 7, step 7): a small catalogue of
/// prominent craters, and where each sits on the disk tonight (libration,
/// the axis's turn) with the Sun's height over it. A crater 5–15° inside the
/// terminator on the lit side has long shadows: the best detail to focus on.
public enum Craters {
    public struct Crater: Sendable, Equatable {
        public let name: String
        /// Selenographic latitude (north +) and longitude (east +, toward
        /// Mare Crisium), degrees.
        public let latDeg: Double
        public let lonDeg: Double
    }

    public static let catalogue: [Crater] = [
        ("Copernicus", 9.6, -20.1), ("Tycho", -43.3, -11.2), ("Plato", 51.6, -9.4), ("Clavius", -58.4, -14.4),
        ("Aristarchus", 23.7, -47.4), ("Kepler", 8.1, -38.0), ("Archimedes", 29.7, -4.0),
        ("Ptolemaeus", -9.3, -1.9), ("Alphonsus", -13.4, -2.8), ("Arzachel", -18.2, -1.9),
        ("Theophilus", -11.4, 26.4), ("Cyrillus", -13.2, 24.0), ("Catharina", -18.1, 23.4),
        ("Langrenus", -8.9, 61.1), ("Petavius", -25.1, 60.4), ("Posidonius", 31.8, 29.9),
        ("Eratosthenes", 14.5, -11.3), ("Gassendi", -17.6, -40.1), ("Grimaldi", -5.2, -68.3),
        ("Schickard", -44.3, -54.6), ("Maginus", -50.5, -6.3), ("Aristoteles", 50.2, 17.4),
        ("Eudoxus", 44.3, 16.3), ("Atlas", 46.7, 44.4), ("Hercules", 46.7, 39.1), ("Proclus", 16.1, 46.8),
        ("Cleomedes", 27.7, 55.5), ("Albategnius", -11.7, 4.0), ("Hipparchus", -5.1, 5.2),
        ("Walter", -33.0, 0.7), ("Maurolycus", -41.8, 14.0), ("Stöfler", -41.1, 6.0),
        ("Bullialdus", -20.7, -22.2), ("Pitatus", -29.9, -13.5), ("Longomontanus", -49.5, -21.7),
    ].map { Crater(name: $0.0, latDeg: $0.1, lonDeg: $0.2) }

    /// Where a crater appears: a sky offset from the Moon's centre in units
    /// of its radius (+x toward increasing azimuth, +y up), whether it is on
    /// the near side, and the Sun's altitude over it (degrees; negative in
    /// the dark).
    public struct Place: Sendable {
        public let crater: Crater
        public let x: Double
        public let y: Double
        public let visible: Bool
        public let sunAltitudeDeg: Double
    }

    public static func place(_ c: Crater, at date: Date, from site: Site) -> Place {
        let lib = Ephemeris.libration(at: date)
        let (lat, dl) = (deg2rad(c.latDeg), deg2rad(c.lonDeg - lib.lonDeg))
        let b = deg2rad(lib.latDeg)
        // On the disk, lunar north up and lunar east (Crisium) along X.
        let east = cos(lat) * sin(dl)
        let north = sin(lat) * cos(b) - cos(lat) * sin(b) * cos(dl)
        let toward = cos(lat) * cos(b) * cos(dl) + sin(lat) * sin(b)
        // Lunar north in the sky frame; lunar east lies toward the sky's west,
        // which in this frame (as seen, x to increasing azimuth) is north
        // turned 90° clockwise.
        let t = deg2rad(Ephemeris.moonNorthFromZenithDeg(at: date, from: site))
        let n = (x: sin(t), y: cos(t))
        let w = (x: cos(t), y: -sin(t))
        let x = east * w.x + north * n.x
        let y = east * w.y + north * n.y
        // The Sun's direction in (sky x, sky y, toward the observer).
        let phase = Ephemeris.phase(at: date, from: site)
        let i = deg2rad(phase.phaseAngleDeg)
        let s = (phase.brightLimb.x * sin(i), phase.brightLimb.y * sin(i), cos(i))
        let alt = rad2deg(asin(min(1, max(-1, s.0 * x + s.1 * y + s.2 * toward))))
        return Place(crater: c, x: x, y: y, visible: toward > 0, sunAltitudeDeg: alt)
    }

    /// The best crater to focus on now: on the near side, away from the
    /// limb, with the Sun 5–15° up over it (nearest 10°). Near full Moon no
    /// catalogue crater has the Sun that low away from the limb (2026-11-22,
    /// 97% lit: the button went missing), so then the sunlit one with the
    /// Sun lowest over it: the most relief there is. Nil only if none is lit.
    public static func best(at date: Date, from site: Site) -> Place? {
        let places = catalogue.map { place($0, at: date, from: site) }
            .filter { $0.visible && hypot($0.x, $0.y) < 0.85 }
        return places.filter { $0.sunAltitudeDeg > 4 && $0.sunAltitudeDeg < 16 }
            .min { abs($0.sunAltitudeDeg - 10) < abs($1.sunAltitudeDeg - 10) }
            ?? places.filter { $0.sunAltitudeDeg > 4 }.min { $0.sunAltitudeDeg < $1.sunAltitudeDeg }
    }
}
