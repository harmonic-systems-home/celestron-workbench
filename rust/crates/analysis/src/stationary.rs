//! The stationary bench analysis (plan Prompt 5, ADR 0007): timing, still
//! windows, noise and drift while still, angle resolution versus window
//! length, and the rotation between consecutive still windows.

use cwb_protocol::{Nanos, Seq};
use cwb_storage::clockfit::ClockModel;
use serde::Serialize;

use crate::{
    config::Config,
    data::{Motion, Raw, SessionData, Source},
    math::{self, Quat, Summary},
};

const STANDARD_GRAVITY: f64 = 9.80665;

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Analysis {
    pub software: Software,
    pub config: Config,
    pub config_sha256: String,
    pub source: Source,
    /// Phone time of the first device-motion sample; every `*_s` is relative to it.
    pub t0_phone_ns: Nanos,
    pub duration_s: f64,
    pub timing: Timing,
    pub windows: Vec<Window>,
    pub exclusions: Vec<String>,
    pub steady_state_s: f64,
    pub noise: Vec<WindowNoise>,
    pub resolution: Option<ResolutionTable>,
    pub moves: Vec<Move>,
    pub markers: Vec<MarkerAt>,
    pub acceptance: Vec<Check>,
    pub decision: String,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Software {
    pub analysis: String,
    pub method: &'static str,
    pub database_schema: u32,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Timing {
    pub streams: Vec<StreamTiming>,
    pub missing: Vec<(Seq, Seq)>,
    pub missing_samples: u64,
    pub dropped_on_phone: u64,
    pub clock: Vec<ClockModel>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct StreamTiming {
    pub stream: &'static str,
    pub samples: usize,
    pub rate_hz: Option<f64>,
    /// Interval statistics in ms.
    pub interval: Option<Summary>,
    pub interval_min_ms: Option<f64>,
    pub interval_max_ms: Option<f64>,
    /// Intervals longer than `max_gap_intervals` nominal intervals.
    pub long_intervals: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Window {
    pub index: usize,
    pub start_s: f64,
    pub end_s: f64,
    pub duration_s: f64,
    /// Used for steady-state metrics (not inside the warm-up).
    pub steady: bool,
    /// Mean gravity direction in the device frame (unit vector, pointing down).
    pub gravity_device: [f64; 3],
    #[serde(skip)]
    pub range: (usize, usize),
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Channel {
    pub name: &'static str,
    pub unit: &'static str,
    pub summary: Summary,
    /// Least-squares drift across the window, per minute.
    pub drift_per_min: Option<f64>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct WindowNoise {
    pub window: usize,
    pub duration_s: f64,
    /// Raw accelerometer magnitude, in g.
    pub accel_magnitude_g: Option<f64>,
    pub channels: Vec<Channel>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ResolutionTable {
    /// The steady window the table comes from (the longest).
    pub window: usize,
    pub channels: Vec<(&'static str, &'static str)>,
    pub rows: Vec<ResolutionRow>,
    /// Per channel: (τ s, Allan deviation) at the minimum found.
    pub minimum: Vec<Option<(f64, f64)>>,
    pub coverage_k: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ResolutionRow {
    pub tau_s: f64,
    /// Allan deviation per channel, in the channel's unit.
    pub adev: Vec<Option<f64>>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Move {
    pub from: usize,
    pub to: usize,
    /// Rotation from one window's mean attitude to the next, in the first
    /// window's device frame.
    pub angle_deg: f64,
    pub axis_device: [f64; 3],
    /// Change of heading about the reference frame's vertical.
    pub heading_deg: f64,
    /// Angle between the windows' mean gravity directions.
    pub gravity_change_deg: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MarkerAt {
    pub label: String,
    pub t_s: f64,
    /// The still window containing the marker, if any.
    pub window: Option<usize>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Pass,
    Fail,
    NotMeasured,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Check {
    pub name: String,
    pub value: String,
    pub limit: String,
    pub outcome: Outcome,
}

pub const METHOD: &str = "stationary_v1";

pub fn analyze(data: &SessionData, config: &Config, config_sha256: &str) -> Analysis {
    let t0 = data
        .motion
        .first()
        .map(|m| m.t_ns)
        .or_else(|| data.gyro.first().map(|r| r.t_ns))
        .unwrap_or(0);
    let secs = |t: Nanos| (t - t0) as f64 / 1e9;
    let duration_s = data.motion.last().map_or(0.0, |m| secs(m.t_ns));
    let nominal_s = data
        .source
        .requested_interval_s
        .filter(|s| *s > 0.0)
        .unwrap_or_else(|| median_interval_s(data.motion.iter().map(|m| m.t_ns)));

    let timing = timing(data, config, nominal_s);
    let mut exclusions = Vec::new();
    if config.exclusions.warm_up_s > 0.0 {
        exclusions.push(format!(
            "warm-up: 0–{:.1} s excluded from steady-state metrics",
            config.exclusions.warm_up_s
        ));
    }
    let windows = still_windows(data, config, nominal_s, t0, &mut exclusions);
    let steady_state_s = windows
        .iter()
        .filter(|w| w.steady)
        .map(|w| w.duration_s)
        .sum();
    let noise: Vec<WindowNoise> = windows
        .iter()
        .filter(|w| w.steady)
        .map(|w| window_noise(data, w))
        .collect();
    let resolution = windows
        .iter()
        .filter(|w| w.steady)
        .max_by(|a, b| a.duration_s.total_cmp(&b.duration_s))
        .map(|w| resolution(data, w, config));
    let moves = windows
        .windows(2)
        .map(|pair| movement(data, &pair[0], &pair[1]))
        .collect();
    let markers = data
        .markers
        .iter()
        .map(|(label, t)| {
            let t_s = secs(*t);
            MarkerAt {
                label: label.clone(),
                t_s,
                window: windows
                    .iter()
                    .find(|w| w.start_s <= t_s && t_s <= w.end_s)
                    .map(|w| w.index),
            }
        })
        .collect();
    let acceptance = acceptance(data, config, &timing, steady_state_s);
    let decision = if acceptance.iter().any(|c| c.outcome == Outcome::Fail) {
        "not accepted: see failed checks".to_owned()
    } else if acceptance.iter().any(|c| c.outcome == Outcome::NotMeasured) {
        "provisionally acceptable: some checks not measured".to_owned()
    } else {
        "acceptable as a baseline".to_owned()
    };

    Analysis {
        software: Software {
            analysis: format!("cwb-analysis {}", env!("CARGO_PKG_VERSION")),
            method: METHOD,
            database_schema: cwb_storage::SCHEMA_VERSION,
        },
        config: config.clone(),
        config_sha256: config_sha256.to_owned(),
        source: data.source.clone(),
        t0_phone_ns: t0,
        duration_s,
        timing,
        windows,
        exclusions,
        steady_state_s,
        noise,
        resolution,
        moves,
        markers,
        acceptance,
        decision,
    }
}

fn median_interval_s(times: impl Iterator<Item = Nanos>) -> f64 {
    let t: Vec<Nanos> = times.collect();
    let mut d: Vec<f64> = t.windows(2).map(|w| (w[1] - w[0]) as f64 / 1e9).collect();
    if d.is_empty() {
        return 0.01;
    }
    d.sort_by(f64::total_cmp);
    d[d.len() / 2]
}

fn timing(data: &SessionData, config: &Config, nominal_s: f64) -> Timing {
    let stream = |name: &'static str, times: Vec<Nanos>| {
        let intervals: Vec<f64> = times
            .windows(2)
            .map(|w| (w[1] - w[0]) as f64 / 1e6)
            .collect();
        let span = match (times.first(), times.last()) {
            (Some(a), Some(b)) if b > a => Some((b - a) as f64 / 1e9),
            _ => None,
        };
        StreamTiming {
            stream: name,
            samples: times.len(),
            rate_hz: span.map(|s| (times.len() - 1) as f64 / s),
            interval: math::summarize(&intervals),
            interval_min_ms: intervals.iter().copied().reduce(f64::min),
            interval_max_ms: intervals.iter().copied().reduce(f64::max),
            long_intervals: intervals
                .iter()
                .filter(|d| **d > config.still.max_gap_intervals * nominal_s * 1e3)
                .count(),
        }
    };
    let mut streams = vec![stream(
        "device_motion",
        data.motion.iter().map(|m| m.t_ns).collect(),
    )];
    if !data.gyro.is_empty() {
        streams.push(stream("gyro", data.gyro.iter().map(|r| r.t_ns).collect()));
    }
    if !data.accel.is_empty() {
        streams.push(stream("accel", data.accel.iter().map(|r| r.t_ns).collect()));
    }
    Timing {
        streams,
        missing: data.missing.clone(),
        missing_samples: data.missing.iter().map(|(a, b)| b - a + 1).sum(),
        dropped_on_phone: data.dropped_on_phone,
        clock: data.clock.clone(),
    }
}

fn still_windows(
    data: &SessionData,
    config: &Config,
    nominal_s: f64,
    t0: Nanos,
    exclusions: &mut Vec<String>,
) -> Vec<Window> {
    let motion = &data.motion;
    let rate_deg: Vec<f64> = motion
        .iter()
        .map(|m| math::norm(m.rate).to_degrees())
        .collect();
    let half = (config.still.smoothing_s / nominal_s / 2.0).round() as usize;
    let mut cum = vec![0.0];
    for r in &rate_deg {
        cum.push(cum.last().copied().unwrap_or(0.0) + r);
    }
    let smoothed = |i: usize| {
        let lo = i.saturating_sub(half);
        let hi = (i + half + 1).min(rate_deg.len());
        (cum[hi] - cum[lo]) / (hi - lo) as f64
    };
    let max_gap_ns = (config.still.max_gap_intervals * nominal_s * 1e9) as Nanos;
    let secs = |t: Nanos| (t - t0) as f64 / 1e9;

    // Runs of still samples, split at timestamp gaps.
    let mut runs: Vec<(usize, usize)> = Vec::new();
    let mut start: Option<usize> = None;
    for i in 0..motion.len() {
        let still = smoothed(i) < config.still.max_rate_deg_s;
        let gap = i > 0 && motion[i].t_ns - motion[i - 1].t_ns > max_gap_ns;
        if let Some(s) = start
            && (!still || gap)
        {
            runs.push((s, i));
            start = None;
        }
        if still && start.is_none() {
            start = Some(i);
        }
    }
    if let Some(s) = start {
        runs.push((s, motion.len()));
    }

    let mut windows = Vec::new();
    let mut short = 0;
    for (s, e) in runs {
        let (ts, te) = (secs(motion[s].t_ns), secs(motion[e - 1].t_ns));
        if te - ts < config.still.min_duration_s {
            short += 1;
            continue;
        }
        let (ts, te) = (ts + config.still.trim_s, te - config.still.trim_s);
        let range = (
            s + motion[s..e].partition_point(|m| secs(m.t_ns) < ts),
            s + motion[s..e].partition_point(|m| secs(m.t_ns) <= te),
        );
        if range.1 <= range.0 + 1 {
            short += 1;
            continue;
        }
        let gravity = math::unit(mean3(
            motion[range.0..range.1]
                .iter()
                .map(|m| math::unit(m.gravity)),
        ));
        windows.push(Window {
            index: windows.len(),
            start_s: ts,
            end_s: te,
            duration_s: te - ts,
            steady: ts >= config.exclusions.warm_up_s,
            gravity_device: gravity,
            range,
        });
    }
    if short > 0 {
        exclusions.push(format!(
            "{short} still period(s) shorter than {:.1} s after trimming were not used",
            config.still.min_duration_s
        ));
    }
    if config.still.trim_s > 0.0 {
        exclusions.push(format!(
            "{:.1} s trimmed from both ends of every still window (settling)",
            config.still.trim_s
        ));
    }
    let warm = windows.iter().filter(|w| !w.steady).count();
    if warm > 0 {
        exclusions.push(format!(
            "{warm} still window(s) start inside the warm-up and are excluded from steady state"
        ));
    }
    windows
}

fn mean3(v: impl Iterator<Item = [f64; 3]>) -> [f64; 3] {
    let mut sum = [0.0; 3];
    let mut n = 0.0f64;
    for x in v {
        for i in 0..3 {
            sum[i] += x[i];
        }
        n += 1.0;
    }
    sum.map(|s| s / n.max(1.0))
}

/// Two axes perpendicular to `down`, preferring the device's X axis.
fn tilt_axes(down: [f64; 3]) -> ([f64; 3], [f64; 3]) {
    let reference = if down[0].abs() < 0.9 {
        [1.0, 0.0, 0.0]
    } else {
        [0.0, 1.0, 0.0]
    };
    let d = math::dot(reference, down);
    let e1 = math::unit([
        reference[0] - d * down[0],
        reference[1] - d * down[1],
        reference[2] - d * down[2],
    ]);
    (e1, math::cross(down, e1))
}

/// Tilt of each vector away from `down`, about the two axes, in degrees.
fn tilts(vectors: impl Iterator<Item = [f64; 3]>, down: [f64; 3]) -> (Vec<f64>, Vec<f64>) {
    let (e1, e2) = tilt_axes(down);
    vectors
        .map(|v| {
            let u = math::unit(v);
            (
                math::dot(u, e1).clamp(-1.0, 1.0).asin().to_degrees(),
                math::dot(u, e2).clamp(-1.0, 1.0).asin().to_degrees(),
            )
        })
        .unzip()
}

/// Heading relative to the window's first sample, unwrapped, in degrees.
fn headings(motion: &[Motion]) -> Vec<f64> {
    let Some(first) = motion.first() else {
        return Vec::new();
    };
    let inverse = math::qconj(math::qnorm(first.q));
    let wrapped: Vec<f64> = motion
        .iter()
        .map(|m| math::twist_about_z(math::qmul(math::qnorm(m.q), inverse)))
        .collect();
    math::unwrap(&wrapped)
        .into_iter()
        .map(f64::to_degrees)
        .collect()
}

fn raw_in(raw: &[Raw], from: Nanos, to: Nanos) -> &[Raw] {
    let a = raw.partition_point(|r| r.t_ns < from);
    let b = raw.partition_point(|r| r.t_ns <= to);
    &raw[a..b.max(a)]
}

/// Every analysed channel of one window, evenly sampled: (name, unit, times s, values).
type Series = (&'static str, &'static str, Vec<f64>, Vec<f64>);

fn window_series(data: &SessionData, w: &Window) -> Vec<Series> {
    let motion = &data.motion[w.range.0..w.range.1];
    let (from, to) = (motion[0].t_ns, motion[motion.len() - 1].t_ns);
    let t = |ts: Nanos| (ts - from) as f64 / 1e9;
    let mt: Vec<f64> = motion.iter().map(|m| t(m.t_ns)).collect();
    let (ta, tb) = tilts(motion.iter().map(|m| m.gravity), w.gravity_device);
    let mut out: Vec<Series> = vec![
        ("tilt_a", "deg", mt.clone(), ta),
        ("tilt_b", "deg", mt.clone(), tb),
        ("heading", "deg", mt, headings(motion)),
    ];
    let accel = raw_in(&data.accel, from, to);
    if accel.len() > 2 {
        let at: Vec<f64> = accel.iter().map(|r| t(r.t_ns)).collect();
        let (xa, xb) = tilts(accel.iter().map(|r| r.v), w.gravity_device);
        out.push(("accel_tilt_a", "deg", at.clone(), xa));
        out.push(("accel_tilt_b", "deg", at, xb));
    }
    let gyro = raw_in(&data.gyro, from, to);
    if gyro.len() > 2 {
        let gt: Vec<f64> = gyro.iter().map(|r| t(r.t_ns)).collect();
        for (i, name) in ["gyro_x", "gyro_y", "gyro_z"].into_iter().enumerate() {
            out.push((
                name,
                "deg/s",
                gt.clone(),
                gyro.iter().map(|r| r.v[i].to_degrees()).collect(),
            ));
        }
    }
    out
}

fn window_noise(data: &SessionData, w: &Window) -> WindowNoise {
    let series = window_series(data, w);
    let motion = &data.motion[w.range.0..w.range.1];
    let accel = raw_in(&data.accel, motion[0].t_ns, motion[motion.len() - 1].t_ns);
    let accel_magnitude_g = (!accel.is_empty()).then(|| {
        accel.iter().map(|r| math::norm(r.v)).sum::<f64>() / accel.len() as f64 / STANDARD_GRAVITY
    });
    WindowNoise {
        window: w.index,
        duration_s: w.duration_s,
        accel_magnitude_g,
        channels: series
            .iter()
            .filter_map(|(name, unit, t, v)| {
                Some(Channel {
                    name,
                    unit,
                    summary: math::summarize(v)?,
                    drift_per_min: math::slope(t, v).map(|s| s * 60.0),
                })
            })
            .collect(),
    }
}

fn resolution(data: &SessionData, w: &Window, config: &Config) -> ResolutionTable {
    let series = window_series(data, w);
    let dt: Vec<f64> = series
        .iter()
        .map(|(_, _, t, _)| (t[t.len() - 1] - t[0]) / (t.len() - 1).max(1) as f64)
        .collect();
    let adev = |i: usize, tau: f64| {
        let m = (tau / dt[i]).round() as usize;
        (m >= 1 && (m as f64) * dt[i] * 3.0 <= w.duration_s)
            .then(|| math::allan_deviation(&series[i].3, m))
            .flatten()
    };
    let rows = config
        .resolution
        .tau_s
        .iter()
        .filter(|tau| **tau * 3.0 <= w.duration_s)
        .map(|&tau_s| ResolutionRow {
            tau_s,
            adev: (0..series.len()).map(|i| adev(i, tau_s)).collect(),
        })
        .collect();
    // Search the minimum over a fine logarithmic grid of averaging times.
    let minimum = (0..series.len())
        .map(|i| {
            let mut best: Option<(f64, f64)> = None;
            let mut m = (config.resolution.min_window_s / dt[i]).max(1.0);
            while m * dt[i] * 3.0 <= w.duration_s {
                let tau = (m.round()) * dt[i];
                if let Some(a) = adev(i, tau)
                    && best.is_none_or(|(_, b)| a < b)
                {
                    best = Some((tau, a));
                }
                m = (m * 1.2).max(m + 1.0);
            }
            best
        })
        .collect();
    ResolutionTable {
        window: w.index,
        channels: series.iter().map(|(n, u, ..)| (*n, *u)).collect(),
        rows,
        minimum,
        coverage_k: config.resolution.coverage_k,
    }
}

fn mean_attitude(data: &SessionData, w: &Window) -> Quat {
    math::qmean(data.motion[w.range.0..w.range.1].iter().map(|m| m.q))
        .unwrap_or([1.0, 0.0, 0.0, 0.0])
}

fn movement(data: &SessionData, a: &Window, b: &Window) -> Move {
    let qa = mean_attitude(data, a);
    let qb = mean_attitude(data, b);
    let (angle, axis) = math::angle_axis(math::qmul(math::qconj(qa), qb));
    let heading = math::twist_about_z(math::qmul(qb, math::qconj(qa)));
    Move {
        from: a.index,
        to: b.index,
        angle_deg: angle.to_degrees(),
        axis_device: axis,
        heading_deg: heading.to_degrees(),
        gravity_change_deg: math::dot(a.gravity_device, b.gravity_device)
            .clamp(-1.0, 1.0)
            .acos()
            .to_degrees(),
    }
}

fn acceptance(
    data: &SessionData,
    config: &Config,
    timing: &Timing,
    steady_state_s: f64,
) -> Vec<Check> {
    let a = &config.acceptance;
    let mut checks = Vec::new();
    let pass = |ok: bool| if ok { Outcome::Pass } else { Outcome::Fail };
    for s in &timing.streams {
        let requested = data.source.requested_interval_s.map(|i| 1.0 / i);
        let (value, outcome) = match (s.rate_hz, requested) {
            (Some(rate), Some(req)) => (
                format!("{rate:.2} Hz of {req:.0} Hz requested"),
                pass(rate >= req * (1.0 - a.max_rate_shortfall)),
            ),
            (Some(rate), None) => (format!("{rate:.2} Hz"), Outcome::NotMeasured),
            _ => ("no samples".into(), Outcome::Fail),
        };
        checks.push(Check {
            name: format!("{} delivered rate", s.stream),
            value,
            limit: format!(
                "≥ {:.0} % of requested",
                (1.0 - a.max_rate_shortfall) * 100.0
            ),
            outcome,
        });
    }
    checks.push(Check {
        name: "missing samples".into(),
        value: format!(
            "{} missing, {} dropped on phone",
            timing.missing_samples, timing.dropped_on_phone
        ),
        limit: format!("≤ {}", a.max_missing_samples),
        outcome: pass(timing.missing_samples + timing.dropped_on_phone <= a.max_missing_samples),
    });
    let worst_clock = timing.clock.iter().map(|m| m.uncertainty_ns).max();
    checks.push(Check {
        name: "clock alignment uncertainty".into(),
        value: worst_clock.map_or("no clock exchanges".into(), |u| {
            format!("±{:.2} ms", u as f64 / 1e6)
        }),
        limit: format!("≤ {} ms", a.max_clock_uncertainty_ms),
        outcome: worst_clock.map_or(Outcome::NotMeasured, |u| {
            pass(u as f64 / 1e6 <= a.max_clock_uncertainty_ms)
        }),
    });
    checks.push(Check {
        name: "steady-state still time".into(),
        value: format!("{steady_state_s:.1} s"),
        limit: format!("≥ {} s", a.min_steady_state_s),
        outcome: pass(steady_state_s >= a.min_steady_state_s),
    });
    checks
}
