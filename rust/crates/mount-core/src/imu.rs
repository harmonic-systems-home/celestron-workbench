//! Turns the phone's fused motion into mount-axis terms (ADR 0013).
//!
//! The phone is strapped to the tube, so one direction in its body frame
//! (`tube`, toward the sky end) is the tube's pointing direction. With the
//! mount level, the azimuth axis is the vertical, which gravity gives
//! directly; the altitude axis is horizontal and perpendicular to the tube.
//! No calibration move is needed, and the phone's roll about the tube
//! doesn't matter.
//!
//! Signs: azimuth is positive clockwise seen from above (compass sense),
//! altitude positive as the tube rises.

use crate::command::{Nanos, Observation};

/// Below this, gravity isn't a usable vertical (m/s²).
const MIN_GRAVITY: f64 = 5.0;
/// cos(altitude) below this: the tube is too near vertical for the
/// altitude axis to be defined (about 87°, beyond any envelope).
const MIN_HORIZONTAL: f64 = 0.05;

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct AxisMapper {
    tube: [f64; 3],
}

impl AxisMapper {
    /// `tube`: the phone body-frame direction toward the tube's sky end,
    /// e.g. `[0, 1, 0]` when the top of the phone points that way.
    pub fn new(tube: [f64; 3]) -> Result<Self, String> {
        let n = norm(tube);
        if !(n.is_finite() && n > 0.5) {
            return Err("tube direction must be a non-zero vector".into());
        }
        Ok(Self {
            tube: scale(tube, 1.0 / n),
        })
    }

    pub fn tube(&self) -> [f64; 3] {
        self.tube
    }

    /// One device-motion sample, already on the Mac clock: rotation rate in
    /// rad/s and gravity in m/s², both in the phone body frame. `None` when
    /// gravity is unusable or the tube is near vertical.
    pub fn observe(
        &self,
        t_ns: Nanos,
        rotation_rate: [f64; 3],
        gravity: [f64; 3],
    ) -> Option<Observation> {
        let g = norm(gravity);
        if !(g.is_finite() && g > MIN_GRAVITY) {
            return None;
        }
        let up = scale(gravity, -1.0 / g);
        let axis = cross(self.tube, up);
        let horizontal = norm(axis);
        if horizontal < MIN_HORIZONTAL {
            return None;
        }
        let altitude_axis = scale(axis, 1.0 / horizontal);
        Some(Observation {
            t_ns,
            rate_deg_s: [
                -dot(rotation_rate, up).to_degrees(),
                dot(rotation_rate, altitude_axis).to_degrees(),
            ],
            altitude_deg: dot(self.tube, up).clamp(-1.0, 1.0).asin().to_degrees(),
        })
    }
}

fn dot(a: [f64; 3], b: [f64; 3]) -> f64 {
    a[0] * b[0] + a[1] * b[1] + a[2] * b[2]
}

fn cross(a: [f64; 3], b: [f64; 3]) -> [f64; 3] {
    [
        a[1] * b[2] - a[2] * b[1],
        a[2] * b[0] - a[0] * b[2],
        a[0] * b[1] - a[1] * b[0],
    ]
}

fn norm(a: [f64; 3]) -> f64 {
    dot(a, a).sqrt()
}

fn scale(a: [f64; 3], k: f64) -> [f64; 3] {
    [a[0] * k, a[1] * k, a[2] * k]
}
