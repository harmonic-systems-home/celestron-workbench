//! The stop-form test (docs/observations.md, O1): sends one rate-0 stop
//! command to a still axis and measures, with the mount's own positions,
//! whether either axis starts to creep. Only rate-0 commands can be sent.

use std::{fmt, thread, time::Duration};

use cwb_celestron_discovery::{Link, Outcome, Query, query::Value, transact};
use cwb_mount_core::{Axis, Nanos};
use serde::Serialize;

use crate::{adapter::Clock, encode::device};

/// One of the four rate-0 forms.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum StopForm {
    /// `P 03 dev 06 00 00 00 00`
    VariablePositive,
    /// `P 03 dev 07 00 00 00 00`
    VariableNegative,
    /// `P 02 dev 24 00 00 00 00`
    FixedPositive,
    /// `P 02 dev 25 00 00 00 00`
    FixedNegative,
}

impl StopForm {
    pub const ALL: [StopForm; 4] = [
        StopForm::VariablePositive,
        StopForm::VariableNegative,
        StopForm::FixedPositive,
        StopForm::FixedNegative,
    ];

    /// `variable+`, `variable-`, `fixed+` or `fixed-`.
    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "variable+" => StopForm::VariablePositive,
            "variable-" => StopForm::VariableNegative,
            "fixed+" => StopForm::FixedPositive,
            "fixed-" => StopForm::FixedNegative,
            _ => return None,
        })
    }

    /// Always rate 0.
    pub fn bytes(self, axis: Axis) -> [u8; 8] {
        let d = device(axis);
        match self {
            StopForm::VariablePositive => [b'P', 3, d, 6, 0, 0, 0, 0],
            StopForm::VariableNegative => [b'P', 3, d, 7, 0, 0, 0, 0],
            StopForm::FixedPositive => [b'P', 2, d, 36, 0, 0, 0, 0],
            StopForm::FixedNegative => [b'P', 2, d, 37, 0, 0, 0, 0],
        }
    }
}

impl fmt::Display for StopForm {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            StopForm::VariablePositive => "variable+",
            StopForm::VariableNegative => "variable-",
            StopForm::FixedPositive => "fixed+",
            StopForm::FixedNegative => "fixed-",
        })
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Reading {
    pub t_ns: Nanos,
    pub deg: [f64; 2],
}

#[derive(Debug, Clone, Serialize)]
pub struct StopTest {
    pub axis: Axis,
    pub form: StopForm,
    pub bytes: String,
    pub outcome: Outcome,
    pub sent_ns: Nanos,
    pub before: Vec<Reading>,
    pub after: Vec<Reading>,
}

/// Arcseconds per second, endpoint to endpoint; `None` with fewer than two.
pub fn rate_arcsec_s(readings: &[Reading]) -> Option<[f64; 2]> {
    let (a, b) = (readings.first()?, readings.last()?);
    let dt = (b.t_ns - a.t_ns) as f64 / 1e9;
    (readings.len() >= 2 && dt > 0.0).then(|| {
        [0, 1].map(|i| {
            let d = (b.deg[i] - a.deg[i] + 180.0).rem_euclid(360.0) - 180.0;
            d * 3600.0 / dt
        })
    })
}

/// Reads positions every `every` for `duration`.
pub fn watch(
    link: &mut impl Link,
    clock: &Clock,
    duration: Duration,
    every: Duration,
) -> Vec<Reading> {
    let query = Query::PreciseAzmAlt;
    let end = clock() + duration.as_nanos() as Nanos;
    let mut out = Vec::new();
    loop {
        let (outcome, reply) = transact(link, &query.bytes(), query.reply_len(), false);
        if outcome == Outcome::Ok
            && let Some(Value::Angles {
                azm_deg, alt_deg, ..
            }) = query.decode(&reply[..query.reply_len()])
        {
            out.push(Reading {
                t_ns: clock(),
                deg: [azm_deg, alt_deg],
            });
        }
        if clock() >= end {
            return out;
        }
        thread::sleep(every);
    }
}

/// Sends one rate-0 command to `axis` and returns what happened. The caller
/// has already watched the mount (`before`) and confirmed it still.
pub fn send(link: &mut impl Link, clock: &Clock, axis: Axis, form: StopForm) -> (Nanos, Outcome) {
    let sent_ns = clock();
    let (outcome, _) = transact(link, &form.bytes(axis), 0, true);
    (sent_ns, outcome)
}

/// Ways to try to cancel a variable-rate creep, in the order the sweep tries
/// them (docs/observations.md, O1). None starts motion except the last,
/// which moves a few arcseconds at fixed rate 1.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Cancel {
    FixedZeroPositive,
    FixedZeroNegative,
    /// `T 00`: the hand controller's tracking off.
    TrackingOff,
    /// The motor controllers' guide rate as 24 bits (`P 04 dev 06|07 00 00 00`).
    GuideRate24ZeroPositive,
    GuideRate24ZeroNegative,
    /// `M`: the hand controller's cancel goto.
    CancelGoto,
    /// Fixed rate 1 for 0.3 s, then fixed rate 0.
    FixedNudge,
}

/// One serial command: bytes, reply payload length, pass-through, then a pause.
pub struct Step {
    pub bytes: Vec<u8>,
    pub reply_len: usize,
    pub pass_through: bool,
    pub pause: Duration,
}

impl Cancel {
    pub const ALL: [Cancel; 7] = [
        Cancel::FixedZeroPositive,
        Cancel::FixedZeroNegative,
        Cancel::TrackingOff,
        Cancel::GuideRate24ZeroPositive,
        Cancel::GuideRate24ZeroNegative,
        Cancel::CancelGoto,
        Cancel::FixedNudge,
    ];

    pub fn steps(self, axis: Axis) -> Vec<Step> {
        let d = device(axis);
        let pt = |bytes: [u8; 8]| Step {
            bytes: bytes.to_vec(),
            reply_len: 0,
            pass_through: true,
            pause: Duration::ZERO,
        };
        let hc = |bytes: &[u8]| Step {
            bytes: bytes.to_vec(),
            reply_len: 0,
            pass_through: false,
            pause: Duration::ZERO,
        };
        match self {
            Cancel::FixedZeroPositive => vec![pt([b'P', 2, d, 36, 0, 0, 0, 0])],
            Cancel::FixedZeroNegative => vec![pt([b'P', 2, d, 37, 0, 0, 0, 0])],
            Cancel::TrackingOff => vec![hc(&[b'T', 0])],
            Cancel::GuideRate24ZeroPositive => vec![pt([b'P', 4, d, 6, 0, 0, 0, 0])],
            Cancel::GuideRate24ZeroNegative => vec![pt([b'P', 4, d, 7, 0, 0, 0, 0])],
            Cancel::CancelGoto => vec![hc(b"M")],
            Cancel::FixedNudge => vec![
                Step {
                    pause: Duration::from_millis(300),
                    ..pt([b'P', 2, d, 36, 1, 0, 0, 0])
                },
                pt([b'P', 2, d, 36, 0, 0, 0, 0]),
            ],
        }
    }
}

impl fmt::Display for Cancel {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(match self {
            Cancel::FixedZeroPositive => "fixed rate 0, positive",
            Cancel::FixedZeroNegative => "fixed rate 0, negative",
            Cancel::TrackingOff => "tracking off (T 00)",
            Cancel::GuideRate24ZeroPositive => "24-bit guide rate 0, positive",
            Cancel::GuideRate24ZeroNegative => "24-bit guide rate 0, negative",
            Cancel::CancelGoto => "cancel goto (M)",
            Cancel::FixedNudge => "fixed rate 1 for 0.3 s, then fixed rate 0",
        })
    }
}

/// Runs a candidate's steps; returns each step's bytes (hex) and outcome.
pub fn run_cancel(link: &mut impl Link, axis: Axis, cancel: Cancel) -> Vec<(String, Outcome)> {
    cancel
        .steps(axis)
        .into_iter()
        .map(|s| {
            let (outcome, _) = transact(link, &s.bytes, s.reply_len, s.pass_through);
            thread::sleep(s.pause);
            let hex: Vec<String> = s.bytes.iter().map(|b| format!("{b:02X}")).collect();
            (hex.join(" "), outcome)
        })
        .collect()
}
