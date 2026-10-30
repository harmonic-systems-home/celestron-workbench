//! The safety configuration: fixed before a session, stored with it, and
//! checked before it is used (ADR 0005).

use serde::{Deserialize, Serialize};

/// Times are milliseconds, rates degrees per second, angles degrees.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SafetyConfig {
    /// Highest commandable axis rate.
    pub max_rate_deg_s: f64,
    /// Lowest commandable rate. A single slow or short move may be too small
    /// for the IMU to see; the accumulated travel check covers it instead.
    pub min_rate_deg_s: f64,
    /// Longest lease for one command; the controller stops the axis when it ends.
    pub max_duration_ms: u64,
    /// A move must leave for the mount within this time of being handed to
    /// the adapter, which may first finish a position read in progress.
    pub send_deadline_ms: u64,
    /// The mount must acknowledge a command within this time of its leaving.
    pub ack_deadline_ms: u64,
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
    /// Accumulated travel check: once the net commanded travel on an axis
    /// since its last confirmation reaches this, the IMU must confirm it.
    /// No commanded position strays further than this unconfirmed. Keep it
    /// well above the gear backlash, which absorbs motion after a reversal.
    pub verify_travel_deg: f64,
    /// Observed travel must reach this fraction of the commanded travel, in
    /// the commanded direction, for the check to pass.
    pub min_observed_fraction: f64,
    /// An axis that has turned more than this beyond its commanded travel
    /// (since the last confirmation, or since it was last seen still after
    /// a fault) is moving on its own: this catches a creep too slow for the
    /// rate checks, such as a slow move whose stop was ignored. Observed
    /// travel is integrated from IMU rates, so gyro bias accumulates too:
    /// disarm during long holds.
    pub travel_tolerance_deg: f64,
    /// Gotos (ADR 0014). Longest distance per leg. Until a stop has been
    /// shown to end a goto on the mount, keep this to about 1 s of travel at
    /// the slow speed, so a goto the stop can't end still ends on its own.
    pub max_goto_deg: f64,
    /// Overspeed for a goto: observed rate above this × (1 +
    /// `overspeed_fraction`) + `motion_deg_s`.
    pub max_goto_rate_deg_s: f64,
    /// A goto must finish within distance / this + `goto_settle_ms` of
    /// leaving, or it times out.
    pub min_goto_rate_deg_s: f64,
    pub goto_settle_ms: u64,
    /// Fast gotos stay refused until their speed has been measured and
    /// `max_goto_rate_deg_s` set from it.
    pub allow_fast_goto: bool,
    /// How far past the target the approach flag's first leg goes. It must
    /// exceed the gear backlash. Within this distance of a leg's target,
    /// a servo's brief reversal isn't opposite motion; further past the
    /// target than this is an overshoot fault.
    pub approach_margin_deg: f64,
    /// A goto that settles further than this from its target missed it.
    pub goto_tolerance_deg: f64,
    /// With anti-backlash set, a move that reverses its axis starts by taking
    /// up the slack fast (0.9 °/s peaks at 99, O14): for `takeup_ms` after
    /// it leaves, the overspeed limit rises by this much. 0 without
    /// anti-backlash.
    pub takeup_overspeed_deg_s: f64,
    pub takeup_ms: u64,
}

impl Default for SafetyConfig {
    /// Conservative indoor values: at most 1 °/s for 2 s (2° per command),
    /// and at most 1° commanded on an axis before the IMU must confirm it.
    fn default() -> Self {
        Self {
            max_rate_deg_s: 1.0,
            min_rate_deg_s: 0.001,
            max_duration_ms: 2_000,
            send_deadline_ms: 1_000,
            ack_deadline_ms: 300,
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
            verify_travel_deg: 1.0,
            min_observed_fraction: 0.5,
            travel_tolerance_deg: 0.25,
            max_goto_deg: 0.05,
            max_goto_rate_deg_s: 1.0,
            min_goto_rate_deg_s: 0.05,
            goto_settle_ms: 2_000,
            allow_fast_goto: false,
            approach_margin_deg: 0.15,
            goto_tolerance_deg: 0.01,
            takeup_overspeed_deg_s: 0.0,
            takeup_ms: 0,
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
            ("verify_travel_deg", self.verify_travel_deg),
            ("travel_tolerance_deg", self.travel_tolerance_deg),
            ("max_goto_deg", self.max_goto_deg),
            ("max_goto_rate_deg_s", self.max_goto_rate_deg_s),
            ("min_goto_rate_deg_s", self.min_goto_rate_deg_s),
            ("approach_margin_deg", self.approach_margin_deg),
            ("goto_tolerance_deg", self.goto_tolerance_deg),
        ];
        for (name, v) in positive {
            if !(v.is_finite() && v > 0.0) {
                p.push(format!("{name} must be positive"));
            }
        }
        for (name, v) in [
            ("max_duration_ms", self.max_duration_ms),
            ("send_deadline_ms", self.send_deadline_ms),
            ("ack_deadline_ms", self.ack_deadline_ms),
            ("stop_deadline_ms", self.stop_deadline_ms),
            ("imu_max_age_ms", self.imu_max_age_ms),
            ("smoothing_ms", self.smoothing_ms),
            ("stop_resend_ms", self.stop_resend_ms),
            ("goto_settle_ms", self.goto_settle_ms),
        ] {
            if v == 0 {
                p.push(format!("{name} must be positive"));
            }
        }
        if self.min_rate_deg_s > self.max_rate_deg_s {
            p.push("min_rate_deg_s exceeds max_rate_deg_s".into());
        }
        if !(self.min_observed_fraction > 0.0 && self.min_observed_fraction <= 1.0) {
            p.push("min_observed_fraction must be above 0 and at most 1".into());
        }
        if self.still_deg_s >= self.motion_deg_s {
            p.push("still_deg_s must be below motion_deg_s".into());
        }
        if !(self.takeup_overspeed_deg_s.is_finite() && self.takeup_overspeed_deg_s >= 0.0) {
            p.push("takeup_overspeed_deg_s must be 0 or more".into());
        }
        if self.min_goto_rate_deg_s > self.max_goto_rate_deg_s {
            p.push("min_goto_rate_deg_s exceeds max_goto_rate_deg_s".into());
        }
        if self.goto_tolerance_deg >= self.approach_margin_deg {
            p.push("goto_tolerance_deg must be below approach_margin_deg".into());
        }
        if self.min_altitude_deg >= self.max_altitude_deg {
            p.push("altitude envelope is empty".into());
        }
        p
    }
}
