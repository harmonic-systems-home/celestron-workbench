import Foundation

/// Whether it's night, for the palette: the Sun 6° below the horizon (civil
/// dusk) at the site Moon Mosaic saved, or 19:00 to 07:00 without one. The
/// site is read, never stored here.
enum Daylight {
    static func isNight(at date: Date = Date()) -> Bool {
        guard let (lat, lon) = savedSite() else {
            let hour = Calendar.current.component(.hour, from: date)
            return hour >= 19 || hour < 7
        }
        return sunAltitudeDeg(at: date, latitudeDeg: lat, longitudeDeg: lon) < -6
    }

    /// Moon Mosaic's settings file, if it has a site in it.
    static func savedSite() -> (Double, Double)? {
        let file = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
            0
        ]
        .appendingPathComponent("MoonMosaic/settings.json")
        guard let data = try? Data(contentsOf: file),
            let d = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let lat = d["latitude"] as? Double, let lon = d["longitude"] as? Double,
            lat != 0 || lon != 0
        else { return nil }
        return (lat, lon)
    }

    /// The Sun's altitude to about a degree (the low-precision formulae of
    /// the Astronomical Almanac); longitude east-positive.
    static func sunAltitudeDeg(at date: Date, latitudeDeg: Double, longitudeDeg: Double) -> Double {
        let r = Double.pi / 180
        let d = date.timeIntervalSince1970 / 86400 + 2_440_587.5 - 2_451_545.0
        let g = (357.529 + 0.985_600_28 * d) * r
        let q = 280.459 + 0.985_647_36 * d
        let l = (q + 1.915 * sin(g) + 0.020 * sin(2 * g)) * r
        let e = (23.439 - 0.000_000_36 * d) * r
        let ra = atan2(cos(e) * sin(l), cos(l))
        let dec = asin(sin(e) * sin(l))
        let gmst = (280.460_618_37 + 360.985_647_366_29 * d) * r
        let hour = gmst + longitudeDeg * r - ra
        let lat = latitudeDeg * r
        return asin(sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(hour)) / r
    }
}
