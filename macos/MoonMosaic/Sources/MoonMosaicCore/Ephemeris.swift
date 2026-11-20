import Foundation

/// Where the observer is. Longitude is positive east.
public struct Site: Sendable, Equatable {
    public var latitudeDeg: Double
    public var longitudeDeg: Double

    public init(latitudeDeg: Double, longitudeDeg: Double) {
        self.latitudeDeg = latitudeDeg
        self.longitudeDeg = longitudeDeg
    }
}

/// A direction on the sky, in degrees.
public struct Equatorial: Sendable, Equatable {
    public var raDeg: Double
    public var decDeg: Double
}

/// As the mount sees it: azimuth clockwise from north, altitude up.
public struct Horizontal: Sendable, Equatable {
    public var azDeg: Double
    public var altDeg: Double
}

/// The Moon as seen from the site.
public struct MoonView: Sendable, Equatable {
    /// Topocentric and refracted: where to point.
    public var horizontal: Horizontal
    public var distanceKm: Double
    /// Its apparent diameter.
    public var diameterDeg: Double
}

/// Low-precision positions of the Sun and Moon (ADR 0019), after Paul
/// Schlyter's "How to compute planetary positions": orbital elements plus
/// the main perturbations, good to 1–2 arcminutes, of the equinox of date.
/// The app uses only how the Moon's position changes over minutes, so a
/// near-constant error cancels; what changes over minutes (the sky's
/// rotation, the Moon's parallax, refraction) is computed in full.
public enum Ephemeris {
    static let earthRadiusKm = 6378.14
    static let moonRadiusKm = 1737.4

    /// Julian day (UT) of a date.
    public static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86_400 + 2_440_587.5
    }

    /// Days from 2000 January 0.0 (Schlyter's day number).
    static func day(_ jd: Double) -> Double { jd - 2_451_543.5 }

    static func obliquityDeg(_ d: Double) -> Double { 23.4393 - 3.563e-7 * d }

    /// Greenwich mean sidereal time, degrees (Meeus 12.4).
    public static func gmstDeg(_ jd: Double) -> Double {
        let t = (jd - 2_451_545.0) / 36_525
        let theta =
            280.46061837 + 360.98564736629 * (jd - 2_451_545.0) + 0.000387933 * t * t
            - t * t * t / 38_710_000
        return normalize(theta)
    }

    // MARK: Sun

    /// The Sun's ecliptic longitude (degrees) and distance (AU).
    static func sunEcliptic(_ d: Double) -> (lonDeg: Double, distanceAU: Double) {
        let w = 282.9404 + 4.70935e-5 * d
        let e = 0.016709 - 1.151e-9 * d
        let m = normalize(356.0470 + 0.9856002585 * d)
        let ea = m + rad2deg(e * sin(deg2rad(m)) * (1 + e * cos(deg2rad(m))))
        let xv = cos(deg2rad(ea)) - e
        let yv = sqrt(1 - e * e) * sin(deg2rad(ea))
        let v = rad2deg(atan2(yv, xv))
        return (normalize(v + w), sqrt(xv * xv + yv * yv))
    }

    public static func sun(at date: Date) -> Equatorial {
        let d = day(julianDay(date))
        let (lon, _) = sunEcliptic(d)
        return equatorial(lonDeg: lon, latDeg: 0, obliquityDeg: obliquityDeg(d))
    }

    // MARK: Moon

    /// The Moon's geocentric ecliptic longitude and latitude (degrees) and
    /// distance (Earth radii).
    static func moonEcliptic(_ d: Double) -> (lonDeg: Double, latDeg: Double, distanceER: Double) {
        let n = 125.1228 - 0.0529538083 * d
        let i = 5.1454
        let w = 318.0634 + 0.1643573223 * d
        let a = 60.2666
        let e = 0.054900
        let m = normalize(115.3654 + 13.0649929509 * d)
        var ea = m + rad2deg(e * sin(deg2rad(m)) * (1 + e * cos(deg2rad(m))))
        for _ in 0..<5 {
            ea -= (ea - rad2deg(e * sin(deg2rad(ea))) - m) / (1 - e * cos(deg2rad(ea)))
        }
        let xv = a * (cos(deg2rad(ea)) - e)
        let yv = a * sqrt(1 - e * e) * sin(deg2rad(ea))
        let v = rad2deg(atan2(yv, xv))
        var r = sqrt(xv * xv + yv * yv)
        let (sn, cn) = (sin(deg2rad(n)), cos(deg2rad(n)))
        let (svw, cvw) = (sin(deg2rad(v + w)), cos(deg2rad(v + w)))
        let ci = cos(deg2rad(i))
        let xh = r * (cn * cvw - sn * svw * ci)
        let yh = r * (sn * cvw + cn * svw * ci)
        let zh = r * svw * sin(deg2rad(i))
        var lon = rad2deg(atan2(yh, xh))
        var lat = rad2deg(atan2(zh, sqrt(xh * xh + yh * yh)))

        // Perturbations (degrees, and Earth radii for the distance).
        let ms = normalize(356.0470 + 0.9856002585 * d)
        let ls = ms + 282.9404 + 4.70935e-5 * d
        let lm = m + w + n
        let dd = lm - ls
        let f = lm - n
        let s = { (x: Double) in sin(deg2rad(x)) }
        let c = { (x: Double) in cos(deg2rad(x)) }
        lon +=
            -1.274 * s(m - 2 * dd) + 0.658 * s(2 * dd) - 0.186 * s(ms)
            - 0.059 * s(2 * m - 2 * dd) - 0.057 * s(m - 2 * dd + ms) + 0.053 * s(m + 2 * dd)
            + 0.046 * s(2 * dd - ms) + 0.041 * s(m - ms) - 0.035 * s(dd) - 0.031 * s(m + ms)
            - 0.015 * s(2 * f - 2 * dd) + 0.011 * s(m - 4 * dd)
        lat +=
            -0.173 * s(f - 2 * dd) - 0.055 * s(m - f - 2 * dd) - 0.046 * s(m + f - 2 * dd)
            + 0.033 * s(f + 2 * dd) + 0.017 * s(2 * m + f)
        r += -0.58 * c(m - 2 * dd) - 0.46 * c(2 * dd)
        return (normalize(lon), lat, r)
    }

    /// The Moon's geocentric position.
    public static func moon(at date: Date) -> (equatorial: Equatorial, distanceKm: Double) {
        let d = day(julianDay(date))
        let (lon, lat, r) = moonEcliptic(d)
        return (
            equatorial(lonDeg: lon, latDeg: lat, obliquityDeg: obliquityDeg(d)),
            r * earthRadiusKm
        )
    }

    /// The Moon from the site: parallax applied (it lowers the Moon by up to
    /// a degree), then refraction.
    public static func moon(at date: Date, from site: Site) -> MoonView {
        let (eq, distance) = moon(at: date)
        return moon(eq, distanceKm: distance, at: date, from: site)
    }

    /// The Moon from the site, given its geocentric position and distance.
    /// Parallax moves it straight down, toward the horizon, so only the
    /// altitude changes (the Earth's flattening adds a few arcseconds of
    /// azimuth, ignored).
    static func moon(_ eq: Equatorial, distanceKm distance: Double, at date: Date, from site: Site)
        -> MoonView
    {
        let geo = horizontal(eq, at: date, from: site)
        let parallax = asin(earthRadiusKm / distance)
        let alt = rad2deg(deg2rad(geo.altDeg) - parallax * cos(deg2rad(geo.altDeg)))
        // From the site the Moon is nearer by about R sin(alt).
        let topoDistance = distance - earthRadiusKm * sin(deg2rad(alt))
        return MoonView(
            horizontal: Horizontal(azDeg: geo.azDeg, altDeg: alt + refractionDeg(alt)),
            distanceKm: topoDistance,
            diameterDeg: 2 * rad2deg(asin(moonRadiusKm / topoDistance))
        )
    }

    // MARK: Phase

    /// How the Moon is lit as seen from the site (Meeus, *Astronomical
    /// Algorithms*, ch. 48 and 14): the lit fraction, the phase angle, and
    /// the direction of the bright limb in the alt-az sky frame used for
    /// sky offsets (+x toward increasing azimuth, +y toward the zenith).
    /// The terminator is the half-ellipse across the disk at
    /// `a = −cos(phaseAngle)·√(1 − b²)` (radius units, `a` along the bright
    /// limb, `b` across it): the lit side is `a` above that.
    public struct Phase: Sendable, Equatable {
        public let illuminatedFraction: Double
        public let phaseAngleDeg: Double
        /// Toward the bright limb: a unit vector in the sky frame.
        public let brightLimb: (x: Double, y: Double)
        /// The same direction as an angle from the zenith, positive toward
        /// increasing azimuth (clockwise as seen), degrees.
        public let brightLimbFromZenithDeg: Double

        public static func == (a: Phase, b: Phase) -> Bool {
            a.illuminatedFraction == b.illuminatedFraction && a.phaseAngleDeg == b.phaseAngleDeg
                && a.brightLimb.x == b.brightLimb.x && a.brightLimb.y == b.brightLimb.y
        }

        /// Whether a point on the disk, as a sky offset from the Moon's
        /// centre in units of its radius, is sunlit.
        public func isLit(_ x: Double, _ y: Double) -> Bool {
            let a = x * brightLimb.x + y * brightLimb.y
            let b = -x * brightLimb.y + y * brightLimb.x
            guard a * a + b * b <= 1 else { return false }
            return a >= -cos(deg2rad(phaseAngleDeg)) * max(0, 1 - b * b).squareRoot()
        }
    }

    /// The position angle of the Moon's axis (lunar north), degrees from
    /// celestial north through east, and the optical libration's latitude
    /// (Meeus, *Astronomical Algorithms*, ch. 53, without nutation and the
    /// physical libration: good to about 0.1°).
    public static func moonAxis(at date: Date) -> (positionAngleDeg: Double, librationLatDeg: Double) {
        let a = libration(at: date)
        return (a.positionAngleDeg, a.latDeg)
    }

    /// The optical libration in longitude and latitude and the axis's
    /// position angle, degrees (Meeus ch. 53, as `moonAxis`).
    public static func libration(at date: Date) -> (lonDeg: Double, latDeg: Double, positionAngleDeg: Double) {
        let d = day(julianDay(date))
        let (lon, lat, _) = moonEcliptic(d)
        let node = deg2rad(normalize(125.1228 - 0.0529538083 * d))
        let i = deg2rad(1.54242)
        let e = deg2rad(obliquityDeg(d))
        let (l, b) = (deg2rad(lon), deg2rad(lat))
        let w = l - node
        let bLib = asin(-sin(w) * cos(b) * sin(i) - sin(b) * cos(i))
        let x = sin(i) * sin(node)
        let y = sin(i) * cos(node) * cos(e) - cos(i) * sin(e)
        let omega = atan2(x, y)
        let ra = deg2rad(equatorial(lonDeg: lon, latDeg: lat, obliquityDeg: obliquityDeg(d)).raDeg)
        let p = asin(min(1, max(-1, (x * x + y * y).squareRoot() * cos(ra - omega) / cos(bLib))))
        // Longitude: A − F, F the Moon's argument of latitude.
        let aa = atan2(sin(w) * cos(b) * cos(i) - sin(b) * sin(i), cos(w) * cos(b))
        let m = normalize(115.3654 + 13.0649929509 * d)
        let wPerigee = 318.0634 + 0.1643573223 * d
        let f = deg2rad(m + wPerigee)  // mean longitude − node
        var lLib = rad2deg(aa - f)
        lLib -= 360 * (lLib / 360).rounded()
        return (lLib, rad2deg(bLib), rad2deg(p))
    }

    /// Where lunar north points in the sky frame, as an angle from the
    /// zenith positive toward increasing azimuth (the same convention as
    /// `Phase.brightLimbFromZenithDeg`): the axis's position angle turned by
    /// the parallactic angle.
    public static func moonNorthFromZenithDeg(at date: Date, from site: Site) -> Double {
        let (moonEq, _) = moon(at: date)
        let lst = gmstDeg(julianDay(date)) + site.longitudeDeg
        let h = deg2rad(lst - moonEq.raDeg)
        let phi = deg2rad(site.latitudeDeg)
        let dd = deg2rad(moonEq.decDeg)
        let q = rad2deg(atan2(sin(h), tan(phi) * cos(dd) - sin(dd) * cos(h)))
        return normalize(q - moonAxis(at: date).positionAngleDeg)
    }

    /// The sunlit part's outline, in the sky frame in units of the Moon's
    /// radius (+x toward increasing azimuth, +y up): the bright limb's half
    /// circle, then back along the terminator's half ellipse.
    public static func litOutline(
        brightLimbFromZenithDeg limbDeg: Double, phaseAngleDeg: Double, points n: Int = 48
    ) -> [(x: Double, y: Double)] {
        let t = deg2rad(limbDeg)
        let (lx, ly) = (sin(t), cos(t))
        let c = cos(deg2rad(phaseAngleDeg))
        func sky(_ a: Double, _ b: Double) -> (x: Double, y: Double) { (a * lx - b * ly, a * ly + b * lx) }
        var out: [(x: Double, y: Double)] = []
        for k in 0...n {
            let th = -Double.pi / 2 + Double.pi * Double(k) / Double(n)
            out.append(sky(cos(th), sin(th)))
        }
        for k in 0...n {
            let th = Double.pi / 2 - Double.pi * Double(k) / Double(n)
            out.append(sky(-c * cos(th), sin(th)))
        }
        return out
    }

    public static func phase(at date: Date, from site: Site) -> Phase {
        let d = day(julianDay(date))
        let (moonEq, moonKm) = moon(at: date)
        let sunEq = sun(at: date)
        let sunKm = sunEcliptic(d).distanceAU * 149_597_870.7
        // Elongation, then the phase angle (Meeus 48.2–48.3).
        let psi = deg2rad(separationDeg(moonEq, sunEq))
        let i = atan2(sunKm * sin(psi), moonKm - sunKm * cos(psi))
        let k = (1 + cos(i)) / 2
        // Position angle of the bright limb, from celestial north through
        // east (48.5).
        let (a0, d0) = (deg2rad(sunEq.raDeg), deg2rad(sunEq.decDeg))
        let (a, dd) = (deg2rad(moonEq.raDeg), deg2rad(moonEq.decDeg))
        let chi = atan2(
            cos(d0) * sin(a0 - a), sin(d0) * cos(dd) - cos(d0) * sin(dd) * cos(a0 - a))
        // Parallactic angle: celestial north from the zenith direction (14.1).
        let lst = gmstDeg(julianDay(date)) + site.longitudeDeg
        let h = deg2rad(lst - moonEq.raDeg)
        let phi = deg2rad(site.latitudeDeg)
        let q = atan2(sin(h), tan(phi) * cos(dd) - sin(dd) * cos(h))
        // From the zenith direction, through east. East lies toward
        // decreasing azimuth (to the left facing the Moon), so in the sky
        // frame the bright limb is (−sin θ, cos θ).
        let theta = chi - q
        let limb = (x: -sin(theta), y: cos(theta))
        return Phase(
            illuminatedFraction: k, phaseAngleDeg: rad2deg(i), brightLimb: limb,
            brightLimbFromZenithDeg: normalize(rad2deg(atan2(limb.x, limb.y))))
    }

    // MARK: Conversions

    static func equatorial(lonDeg: Double, latDeg: Double, obliquityDeg: Double) -> Equatorial {
        let (l, b, e) = (deg2rad(lonDeg), deg2rad(latDeg), deg2rad(obliquityDeg))
        let ra = atan2(sin(l) * cos(e) - tan(b) * sin(e), cos(l))
        let dec = asin(sin(b) * cos(e) + cos(b) * sin(e) * sin(l))
        return Equatorial(raDeg: normalize(rad2deg(ra)), decDeg: rad2deg(dec))
    }

    /// Geometric (unrefracted) azimuth and altitude.
    public static func horizontal(_ eq: Equatorial, at date: Date, from site: Site) -> Horizontal {
        let lst = gmstDeg(julianDay(date)) + site.longitudeDeg
        let h = deg2rad(lst - eq.raDeg)
        let (phi, dec) = (deg2rad(site.latitudeDeg), deg2rad(eq.decDeg))
        let alt = asin(sin(phi) * sin(dec) + cos(phi) * cos(dec) * cos(h))
        let az = atan2(-sin(h) * cos(dec), cos(phi) * sin(dec) - sin(phi) * cos(dec) * cos(h))
        return Horizontal(azDeg: normalize(rad2deg(az)), altDeg: rad2deg(alt))
    }

    /// How much the air lifts an object at true altitude `altDeg`
    /// (Sæmundsson, 10 °C and 1010 hPa), degrees.
    public static func refractionDeg(_ altDeg: Double) -> Double {
        guard altDeg > -1 else { return 0 }
        let r = 1.02 / tan(deg2rad(altDeg + 10.3 / (altDeg + 5.11)))
        return r / 60
    }

    /// The angle between two directions on the sky, degrees.
    public static func separationDeg(_ a: Equatorial, _ b: Equatorial) -> Double {
        let (d1, d2) = (deg2rad(a.decDeg), deg2rad(b.decDeg))
        let c = sin(d1) * sin(d2) + cos(d1) * cos(d2) * cos(deg2rad(a.raDeg - b.raDeg))
        return rad2deg(acos(min(1, max(-1, c))))
    }

    public static func normalize(_ deg: Double) -> Double {
        let x = deg.truncatingRemainder(dividingBy: 360)
        return x < 0 ? x + 360 : x
    }
}

func deg2rad(_ d: Double) -> Double { d * .pi / 180 }
func rad2deg(_ r: Double) -> Double { r * 180 / .pi }
