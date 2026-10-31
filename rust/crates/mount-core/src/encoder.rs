//! Observations from the motors' own position reads, for sessions without
//! the phone (ADR 0019). The controller's checks (fresh, still, overspeed,
//! opposite motion, stop confirmation, the altitude envelope) then run on
//! encoder rates instead of the IMU's.
//!
//! What this can't see: the tube not following the motor (a slipping
//! clutch), and, while a goto is watched, the other axis, which isn't read
//! then; its rate is taken as its last known one, and as 0 once that is
//! older than `stale_after_ns`.

use crate::command::{Axis, Nanos, Observation};

pub struct EncoderObserver {
    /// Each axis's last reading: (time, degrees).
    last: [Option<(Nanos, f64)>; 2],
    /// Each axis's last rate: (time, °/s).
    rate: [Option<(Nanos, f64)>; 2],
    /// (encoder altitude, true altitude) at one moment, in degrees.
    reference: Option<(f64, f64)>,
    stale_after_ns: Nanos,
}

impl EncoderObserver {
    /// `stale_after_ns`: how long an axis's last rate stands for it while
    /// it isn't being read.
    pub fn new(stale_after_ns: Nanos) -> Self {
        Self {
            last: [None; 2],
            rate: [None; 2],
            reference: None,
            stale_after_ns,
        }
    }

    /// Ties the altitude encoder to the sky: at `encoder_deg` the tube's
    /// true altitude is `altitude_deg` (the app computes it for the Moon it
    /// has just been centred on). Until this is set, observations carry no
    /// altitude, so the envelope check refuses to arm.
    pub fn set_altitude_reference(&mut self, encoder_deg: f64, altitude_deg: f64) {
        self.reference = Some((encoder_deg, altitude_deg));
    }

    /// The tube's true altitude at the last altitude reading, once a
    /// reference is set.
    pub fn altitude_deg(&self) -> Option<f64> {
        let (_, deg) = self.last[Axis::Altitude.index()]?;
        let (enc, alt) = self.reference?;
        Some(alt + wrap(deg - enc))
    }

    /// One axis's position, in degrees of the axis's own angle, read at
    /// `t_ns`. Returns an observation once the axis has a previous reading
    /// to take a rate from.
    pub fn reading(&mut self, axis: Axis, t_ns: Nanos, deg: f64) -> Option<Observation> {
        let i = axis.index();
        let previous = self.last[i];
        if previous.is_some_and(|(t, _)| t_ns <= t) {
            return None;
        }
        self.last[i] = Some((t_ns, deg));
        let (t0, d0) = previous?;
        let rate = wrap(deg - d0) / ((t_ns - t0) as f64 / 1e9);
        self.rate[i] = Some((t_ns, rate));
        let mut rate_deg_s = [0.0; 2];
        for a in Axis::BOTH {
            rate_deg_s[a.index()] = match self.rate[a.index()] {
                Some((t, r)) if t_ns - t <= self.stale_after_ns => r,
                _ => 0.0,
            };
        }
        Some(Observation {
            t_ns,
            rate_deg_s,
            altitude_deg: self.altitude_deg().unwrap_or(f64::NAN),
        })
    }

    /// Both axes read together (an idle read).
    pub fn readings(&mut self, t_ns: Nanos, deg: [f64; 2]) -> Option<Observation> {
        // Altitude first, so the azimuth observation carries both new rates.
        let alt = self.reading(Axis::Altitude, t_ns, deg[1]);
        self.reading(Axis::Azimuth, t_ns, deg[0]).or(alt)
    }
}

fn wrap(d: f64) -> f64 {
    (d + 180.0).rem_euclid(360.0) - 180.0
}

#[cfg(test)]
mod tests {
    use super::*;

    const S: Nanos = 1_000_000_000;

    #[test]
    fn rates_come_from_successive_reads_and_wrap() {
        let mut o = EncoderObserver::new(S);
        assert!(o.reading(Axis::Azimuth, 0, 359.9).is_none());
        let obs = o.reading(Axis::Azimuth, S / 2, 0.1).unwrap();
        assert!((obs.rate_deg_s[0] - 0.4).abs() < 1e-9);
        assert_eq!(obs.rate_deg_s[1], 0.0);
    }

    #[test]
    fn the_other_axis_keeps_its_rate_until_it_goes_stale() {
        let mut o = EncoderObserver::new(S);
        o.reading(Axis::Altitude, 0, 10.0);
        o.reading(Axis::Altitude, S / 4, 10.05);
        o.reading(Axis::Azimuth, S / 4, 0.0);
        let soon = o.reading(Axis::Azimuth, S / 2, 0.0).unwrap();
        assert!((soon.rate_deg_s[1] - 0.2).abs() < 1e-9);
        let late = o.reading(Axis::Azimuth, 2 * S, 0.0).unwrap();
        assert_eq!(late.rate_deg_s[1], 0.0);
    }

    #[test]
    fn altitude_needs_a_reference() {
        let mut o = EncoderObserver::new(S);
        let none = o.readings(0, [0.0, 359.5]);
        assert!(none.is_none());
        let unreferenced = o.readings(S / 4, [0.0, 359.5]).unwrap();
        assert!(unreferenced.altitude_deg.is_nan());
        o.set_altitude_reference(359.5, 31.2);
        let obs = o.readings(S / 2, [0.0, 0.5]).unwrap();
        assert!((obs.altitude_deg - 32.2).abs() < 1e-9);
    }
}
