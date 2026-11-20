import Foundation
import Testing

@testable import MoonMosaicCore

/// Sun avoidance (ADR 0022 amendment 7): moves are judged by where the scope
/// would point, against the Moon, only while the Sun is up, with an override.
@Suite struct SunGuardTests {
    let site = Site(latitudeDeg: 40, longitudeDeg: -100)

    /// A moment when the Sun and the Moon are both well up and 50–90° apart.
    func daytime() -> Date? {
        var t = Date(timeIntervalSince1970: 1_793_491_200)
        for _ in 0..<(24 * 60) {
            let sun = Ephemeris.horizontal(Ephemeris.sun(at: t), at: t, from: site)
            let moon = Ephemeris.moon(at: t, from: site).horizontal
            let sep = MosaicSession.angleDeg(sun, moon)
            if sun.altDeg > 20, moon.altDeg > 20, sep > 50, sep < 90 { return t }
            t.addTimeInterval(3600)
        }
        return nil
    }

    func session(at t: Date) throws -> MosaicSession {
        let mount = try MountSession(port: "simulate")
        return MosaicSession(mount: mount, camera: FakeCamera(), settings: MosaicSettings(site: site), clock: { t })
    }

    @Test func refusesAMoveTowardTheSunAndAllowsOneAway() throws {
        let t = try #require(daytime())
        let s = try session(at: t)
        let sun = s.sunHorizontal(at: t)
        let moon = Ephemeris.moon(at: t, from: site).horizontal
        let sep = MosaicSession.angleDeg(sun, moon)
        // Axis angles that read like the sky plus an arbitrary encoder zero.
        let zero = (az: 123.0, alt: -7.0)
        let p0 = [Ephemeris.normalize(moon.azDeg + zero.az), moon.altDeg + zero.alt]
        s.markOnMoon(p0, at: t)
        #expect(abs(s.sunSeparationDeg(of: p0, at: t) - sep) < 0.1)
        // Toward the Sun, to within about 20° of it.
        let f = (sep - 20) / sep
        let toward = [
            p0[0] + wrap180(sun.azDeg - moon.azDeg) * f, p0[1] + (sun.altDeg - moon.altDeg) * f,
        ]
        #expect(throws: SunTooClose.self) { try s.checkSun(from: p0, to: toward, what: "test") }
        // The same distance the other way is fine.
        let away = [p0[0] - (toward[0] - p0[0]), p0[1] - (toward[1] - p0[1])]
        if (away[1] - zero.alt) < 85 {
            #expect(throws: Never.self) { try s.checkSun(from: p0, to: away, what: "test") }
        }
        // The override: lowered below the closest approach, then off.
        s.sun.overrideDeg = 10
        #expect(throws: Never.self) { try s.checkSun(from: p0, to: toward, what: "test") }
        s.sun.overrideDeg = 0
        #expect(throws: Never.self) { try s.checkSun(from: p0, to: toward, what: "test") }
    }

    @Test func offWhileTheSunIsDown() throws {
        var t = Date(timeIntervalSince1970: 1_793_491_200)
        while Ephemeris.horizontal(Ephemeris.sun(at: t), at: t, from: site).altDeg > -10 {
            t.addTimeInterval(1800)
        }
        let s = try session(at: t)
        #expect(s.sunLimit(at: t) == nil)
        let sun = s.sunHorizontal(at: t)
        let moon = Ephemeris.moon(at: t, from: site).horizontal
        let p0 = [moon.azDeg, moon.altDeg]
        s.markOnMoon(p0, at: t)
        // Even straight at the (set) Sun.
        let at = [p0[0] + wrap180(sun.azDeg - moon.azDeg), p0[1] + sun.altDeg - moon.altDeg]
        #expect(throws: Never.self) { try s.checkSun(from: p0, to: at, what: "test") }
    }

    /// The path counts, not just its end: a move that passes the Sun and
    /// ends beyond it is refused.
    @Test func checksTheWholePath() throws {
        let t = try #require(daytime())
        let s = try session(at: t)
        let sun = s.sunHorizontal(at: t)
        let moon = Ephemeris.moon(at: t, from: site).horizontal
        let p0 = [moon.azDeg, moon.altDeg]
        s.markOnMoon(p0, at: t)
        // Along azimuth only, at the Sun's altitude: from a point well to
        // one side of the Sun to a point well to the other.
        let span = 60 / max(0.2, cos(sun.altDeg * .pi / 180))
        let a = [p0[0] + wrap180(sun.azDeg - moon.azDeg) - span, p0[1] + sun.altDeg - moon.altDeg]
        let b = [a[0] + 2 * span, a[1]]
        #expect(s.sunSeparationDeg(of: a, at: t) > 40)
        #expect(s.sunSeparationDeg(of: b, at: t) > 40)
        #expect(throws: SunTooClose.self) { try s.checkSun(from: a, to: b, what: "test") }
    }
}
