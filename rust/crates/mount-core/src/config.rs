//! The safety configuration: fixed before a session, stored with it, and
//! checked before it is used (ADR 0005).

use serde::{Deserialize, Serialize};

/// Times are milliseconds, rates degrees per second, angles degrees.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SafetyConfig {
    /// Highest commandable axis rate.
    pub max_rate_deg_s: f64,
    /// Lowest commandable rate: below this the IMU cannot confirm the
    /// direction of motion, so the interlocks could not do their job.
    pub min_rate_deg_s: f64,
    /// Longest lease for one command; the controller stops the axis when it ends.
    pub max_duration_ms: u64,
    /// The mount must acknowledge a command within this time.
    pub ack_deadline_ms: u64,
    /// Commanded motion must be seen within this time of transmission.
    pub start_deadline_ms: u64,
    /// After a stop, both axes must be still within this time.
    pub stop_deadline_ms: u64,
    /// Both axes must stay below `still_deg_s` this long to count as stopped.
    pub still_hold_ms: u64,
    /// The newest IMU observation may be at most this old (by its own timestamp).
    pub imu_max_age_ms: u64,
    /// Observed rates are averaged over this window before any check.
    pub smoothing_ms: u64,
    /// Smoothed rate counted as motion.
    pub motion_deg_s: f64,
    /// Smoothed rate below which an axis counts as still.
    pub still_deg_s: f64,
    /// Overspeed: observed rate above commanded × (1 + this) + `motion_deg_s`.
    pub overspeed_fraction: f64,
    /// Altitude envelope (from the IMU); motion outside it is a limit breach.
    pub min_altitude_deg: f64,
    pub max_altitude_deg: f64,
    /// While motion continues after a fault, stop is re-sent this often.
    pub stop_resend_ms: u64,
}

impl Default for SafetyConfig {
    /// Conservative indoor values: at most 1 °/s for 2 s (2° per command).
    fn default() -> Self {
        Self {
            max_rate_deg_s: 1.0,
            min_rate_deg_s: 0.3,
            max_duration_ms: 2_000,
            ack_deadline_ms: 300,
            start_deadline_ms: 1_000,
            stop_deadline_ms: 1_500,
            still_hold_ms: 300,
            imu_max_age_ms: 1_000,
            smoothing_ms: 200,
            motion_deg_s: 0.1,
            still_deg_s: 0.05,
            overspeed_fraction: 0.5,
            min_altitude_deg: 5.0,
            max_altitude_deg: 85.0,
            stop_resend_ms: 250,
        }
    }
}

impl SafetyConfig {
    /// Problems that make the configuration unusable; empty when it is sound.
    pub fn problems(&self) -> Vec<String> {
        let mut p = Vec::new();
        let positive = [
            ("max_rate_deg_s", self.max_rate_deg_s),
            ("min_rate_deg_s", self.min_rate_deg_s),
            ("motion_deg_s", self.motion_deg_s),
            ("still_deg_s", self.still_deg_s),
        ];
        for (name, v) in positive {
            if !(v.is_finite() && v > 0.0) {
                p.push(format!("{name} must be positive"));
            }
        }
        for (name, v) in [
            ("max_duration_ms", self.max_duration_ms),
            ("ack_deadline_ms", self.ack_deadline_ms),
            ("start_deadline_ms", self.start_deadline_ms),
            ("stop_deadline_ms", self.stop_deadline_ms),
            ("imu_max_age_ms", self.imu_max_age_ms),
            ("smoothing_ms", self.smoothing_ms),
            ("stop_resend_ms", self.stop_resend_ms),
        ] {
            if v == 0 {
                p.push(format!("{name} must be positive"));
            }
        }
        if self.min_rate_deg_s > self.max_rate_deg_s {
            p.push("min_rate_deg_s exceeds max_rate_deg_s".into());
        }
        if self.min_rate_deg_s < 2.0 * self.motion_deg_s {
            p.push("min_rate_deg_s must be at least twice motion_deg_s, or direction can't be confirmed".into());
        }
        if self.still_deg_s >= self.motion_deg_s {
            p.push("still_deg_s must be below motion_deg_s".into());
        }
        if self.start_deadline_ms > self.max_duration_ms {
            p.push("start_deadline_ms exceeds max_duration_ms: a stall could go unnoticed".into());
        }
        if self.min_altitude_deg >= self.max_altitude_deg {
            p.push("altitude envelope is empty".into());
        }
        p
    }
}
