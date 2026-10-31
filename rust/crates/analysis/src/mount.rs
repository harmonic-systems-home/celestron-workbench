//! The Phase 2 mount report (ADR 0017): per-move encoder and phone travel
//! from the runner's logs, and from them reversal take-up, over-correction
//! and slack by anti-backlash setting, keypad speeds, link health and command
//! lifecycles. Output depends only on the logs and the config.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::AnalysisError;

/// Motor positions: 24 bits per revolution.
const UNITS_PER_REV: f64 = 16_777_216.0;
const ARCSEC_PER_UNIT: f64 = 1_296_000.0 / UNITS_PER_REV;
/// Celestron's list of keypad rates (°/s): 2, 4, 8, 16 and 32× sidereal,
/// then 0.3, 1, 2 and 4 °/s.
pub const CELESTRON_RATES_DEG_S: [f64; 9] = [
    2.0 * SIDEREAL_DEG_S,
    4.0 * SIDEREAL_DEG_S,
    8.0 * SIDEREAL_DEG_S,
    16.0 * SIDEREAL_DEG_S,
    32.0 * SIDEREAL_DEG_S,
    0.3,
    1.0,
    2.0,
    4.0,
];
const SIDEREAL_DEG_S: f64 = 360.0 / 86_164.090_5;
/// A record's last stage must be one of these.
const TERMINAL: [&str; 5] = ["completed", "cancelled", "rejected", "timed_out", "unknown"];

// --- Config ------------------------------------------------------------------

pub const MOUNT: &str = include_str!("../../../../analysis/mount.toml");

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MountConfig {
    pub version: u32,
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub settle_s: f64,
    pub outliers: Outliers,
    pub scale: ScaleConfig,
    pub geometry: Geometry,
    pub recommend: RecommendConfig,
    pub link: LinkConfig,
    pub findings: Findings,
}

/// Established facts the report quotes as given, each citing its source.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Findings {
    pub protocol: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ScaleConfig {
    pub min_travel_arcsec: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Geometry {
    pub leading_edge_radius_mm: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RecommendConfig {
    /// Keypad rates up to this one are the arrow keys' fine rates the
    /// recommendation is chosen for.
    pub max_keypad_rate: u8,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Outliers {
    pub robust_k: f64,
    pub min_arcsec: f64,
    pub min_moves: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct LinkConfig {
    pub stall_ms: f64,
    pub read_stall_ms: f64,
}

impl MountConfig {
    pub fn parse(text: &str) -> Result<Self, AnalysisError> {
        let config: Self =
            toml::from_str(text).map_err(|e| AnalysisError::Config(e.to_string()))?;
        if config.version != crate::config::CONFIG_VERSION {
            return Err(AnalysisError::Config(format!(
                "config version {} is not supported (expected {})",
                config.version,
                crate::config::CONFIG_VERSION
            )));
        }
        Ok(config)
    }

    pub fn default_config() -> Self {
        Self::parse(MOUNT).expect("the committed mount config parses")
    }
}

// --- Input -------------------------------------------------------------------

/// One run log: its name (the run folder's) and contents.
#[derive(Debug, Clone)]
pub struct RunLog {
    pub name: String,
    pub text: String,
}

/// A discovery report (`cwb celestron discover`): its name and `report.json`.
#[derive(Debug, Clone)]
pub struct DiscoveryLog {
    pub name: String,
    pub text: String,
}

// --- Output ------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Axis {
    Azimuth,
    Altitude,
}

impl Axis {
    pub fn name(self) -> &'static str {
        match self {
            Self::Azimuth => "azimuth",
            Self::Altitude => "altitude",
        }
    }

    fn index(self) -> usize {
        self as usize
    }

    fn parse(s: &str) -> Option<Self> {
        match s {
            "azimuth" => Some(Self::Azimuth),
            "altitude" => Some(Self::Altitude),
            _ => None,
        }
    }
}

/// How a move was commanded.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "snake_case", tag = "type")]
pub enum Kind {
    /// The arrow keys' fixed rates (`MC_MOVE_POS`/`NEG`), for a duration.
    Keypad { rate: u8, duration_ms: u64 },
    /// A variable rate for a duration.
    Timed { rate_deg_s: f64, duration_ms: u64 },
    /// A goto by motor position.
    Goto {
        fast: bool,
        delta_deg: f64,
        approach: bool,
    },
}

impl Kind {
    /// Names the kind and size, without the anti-backlash setting.
    pub fn label(&self) -> String {
        match self {
            Self::Keypad { rate, duration_ms } => {
                format!("keypad r{rate}, {} s", seconds(*duration_ms))
            }
            Self::Timed {
                rate_deg_s,
                duration_ms,
            } => format!("timed {rate_deg_s} °/s, {} s", seconds(*duration_ms)),
            Self::Goto {
                fast,
                delta_deg,
                approach,
            } => format!(
                "goto {} {}°{}",
                if *fast { "fast" } else { "slow" },
                delta_deg.abs(),
                if *approach { ", approach" } else { "" }
            ),
        }
    }

    fn order(&self) -> (u8, i64, i64) {
        match self {
            Self::Keypad { rate, duration_ms } => (0, i64::from(*rate), *duration_ms as i64),
            Self::Timed {
                rate_deg_s,
                duration_ms,
            } => (1, (rate_deg_s * 1e6) as i64, *duration_ms as i64),
            Self::Goto {
                fast,
                delta_deg,
                approach,
            } => (
                2 + u8::from(*fast) * 2 + u8::from(*approach),
                (delta_deg.abs() * 1e6) as i64,
                0,
            ),
        }
    }
}

fn seconds(ms: u64) -> String {
    let s = format!("{:.2}", ms as f64 / 1000.0);
    s.trim_end_matches('0').trim_end_matches('.').to_string()
}

/// How a move relates to the axis's previous motion in the same run.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum History {
    Reversal,
    Repeat,
    /// The first move on the axis in the run, or the first after a move
    /// that didn't complete.
    Unknown,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Move {
    pub run: String,
    pub command_id: u64,
    pub axis: Axis,
    pub kind: Kind,
    /// +1 for positive, −1 for negative.
    pub sign: i8,
    /// The axis's anti-backlash (both directions' values agree in every run
    /// so far; the positive one is used).
    pub anti_backlash: u8,
    /// No setting in the log: the runner then required 0.
    pub anti_backlash_assumed: bool,
    /// Seconds from the run's first event to the command leaving.
    pub t_s: f64,
    /// From the command leaving to the stop leaving (moves only).
    pub duration_s: Option<f64>,
    pub outcome: String,
    pub fault: Option<String>,
    pub history: History,
    /// Travel along the commanded direction (″): positive is the way it was sent.
    pub commanded_arcsec: Option<f64>,
    pub encoder_arcsec: Option<f64>,
    pub phone_arcsec: Option<f64>,
    pub disturbed: bool,
}

impl Move {
    fn usable(&self) -> bool {
        self.fault.is_none()
            && self.outcome == "completed"
            && self.history != History::Unknown
            && self.encoder_arcsec.is_some()
            && self.phone_arcsec.is_some()
    }

    /// Phone − encoder (″): negative is motion the tube didn't follow.
    pub fn residual(&self) -> Option<f64> {
        Some(self.phone_arcsec? - self.encoder_arcsec?)
    }
}

/// Mean with its standard error (None from fewer than two values).
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Estimate {
    pub value: f64,
    pub se: Option<f64>,
}

impl Estimate {
    fn of(x: &[f64]) -> Option<Self> {
        if x.is_empty() {
            return None;
        }
        let n = x.len() as f64;
        let mean = x.iter().sum::<f64>() / n;
        let se = (x.len() > 1).then(|| {
            let var = x.iter().map(|v| (v - mean).powi(2)).sum::<f64>() / (n - 1.0);
            (var / n).sqrt()
        });
        Some(Self { value: mean, se })
    }

    fn minus(self, other: Self) -> Self {
        Self {
            value: self.value - other.value,
            se: match (self.se, other.se) {
                (Some(a), Some(b)) => Some(a.hypot(b)),
                _ => None,
            },
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Side {
    pub n: usize,
    pub encoder: Estimate,
    pub phone: Estimate,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Group {
    pub axis: Axis,
    pub kind: Kind,
    pub label: String,
    pub anti_backlash: u8,
    pub repeats: Option<Side>,
    pub reversals: Option<Side>,
    /// Encoder on reversals − encoder on repeats.
    pub takeup: Option<Estimate>,
    /// Phone on reversals − phone on repeats: 0 is ideal, negative is slack left.
    pub over_correction: Option<Estimate>,
    /// Take-up − over-correction: the lost motion a reversal crossed.
    pub slack: Option<Estimate>,
    pub runs: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Speed {
    pub axis: Axis,
    pub rate: u8,
    pub n: usize,
    pub median_deg_s: f64,
    pub celestron_deg_s: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Link {
    pub run: String,
    pub exchanges: usize,
    pub failures: usize,
    pub median_ms: Option<f64>,
    pub p95_ms: Option<f64>,
    pub max_ms: Option<f64>,
    pub stalls: usize,
    /// Gaps between idle position reads (no command in flight).
    pub read_gaps: usize,
    pub read_gap_median_ms: Option<f64>,
    pub read_gap_p95_ms: Option<f64>,
    pub read_gap_max_ms: Option<f64>,
    pub read_stalls: usize,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Run {
    pub name: String,
    pub sha256: String,
    pub hardware: Option<bool>,
    pub anti_backlash: Option<[u8; 4]>,
    pub requests: usize,
    pub records: usize,
    pub moves: usize,
    pub faults: Vec<String>,
    pub notes: Vec<String>,
    /// Records whose last stage isn't terminal, and requests without a record.
    pub incomplete: Vec<String>,
}

/// A setting's score: the mean |over-correction| of the family's move types
/// tried at it.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Score {
    pub anti_backlash: u8,
    pub mean_abs_over_correction: f64,
    pub kinds: usize,
}

/// The anti-backlash setting a family of moves wants on one axis.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Choice {
    /// The move types considered (kinds tried at two or more settings).
    pub kinds: Vec<String>,
    /// Settings where every one of them was tried, best first.
    pub scores: Vec<Score>,
    pub best: Option<u8>,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Recommendation {
    pub axis: Axis,
    /// The arrow keys' fine rates: what the setting is chosen for.
    pub keypad: Choice,
    /// Timed moves at a variable rate (software), for comparison.
    pub timed: Choice,
    /// The setting in the most recent hardware run's config (the report can't
    /// see changes made since).
    pub configured: Option<u8>,
}

/// What discovery read from the hand controller and motor controllers.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Discovery {
    pub name: String,
    pub sha256: String,
    pub simulated: bool,
    pub model: Option<String>,
    pub hand_controller: Option<String>,
    /// Azimuth, altitude.
    pub motors: Vec<String>,
    pub usb: Option<String>,
    pub link: Option<String>,
    /// azm+, azm−, alt+, alt−, as read.
    pub anti_backlash: Option<[u8; 4]>,
    /// Azimuth, altitude: the motor controllers' own goto approach.
    pub approach: [Option<String>; 2],
    /// The azimuth index-marker query's outcome.
    pub azimuth_index: Option<String>,
    pub position_reply_ms: Option<f64>,
}

/// The phone's travel over the encoder's on one-way moves.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ScaleCheck {
    pub axis: Axis,
    pub moves: usize,
    pub ratio: Estimate,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Acts {
    Yes,
    Partly,
    No,
}

/// Whether anti-backlash acts on one kind of command, from its take-up.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Applies {
    pub axis: Axis,
    /// "keypad r6", "timed", "goto slow", …
    pub commands: String,
    pub acts: Acts,
    pub anti_backlash: u8,
    pub takeup: Estimate,
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MountAnalysis {
    pub method: &'static str,
    pub software_version: &'static str,
    pub config: MountConfig,
    pub config_sha256: String,
    pub runs: Vec<Run>,
    pub moves: Vec<Move>,
    pub groups: Vec<Group>,
    pub discovery: Option<Discovery>,
    pub scale: Vec<ScaleCheck>,
    pub applies: Vec<Applies>,
    /// Typical slack per axis (″): the median over groups with two or more
    /// repeats and reversals.
    pub slack_arcsec: Vec<(Axis, f64)>,
    pub recommendations: Vec<Recommendation>,
    pub speeds: Vec<Speed>,
    pub links: Vec<Link>,
    /// Every successful command exchange's latency (ms), all runs, sorted:
    /// for the distribution plot.
    #[serde(skip)]
    pub latencies_ms: Vec<f64>,
    /// Every idle position-read gap (ms), all runs, sorted.
    #[serde(skip)]
    pub read_gaps_ms: Vec<f64>,
}

// --- Analysis ----------------------------------------------------------------

pub fn analyze(
    logs: &[RunLog],
    discovery: Option<&DiscoveryLog>,
    config: &MountConfig,
    config_sha256: &str,
) -> MountAnalysis {
    let mut runs = Vec::new();
    let mut moves = Vec::new();
    let mut links = Vec::new();
    let mut latencies = Vec::new();
    let mut gaps = Vec::new();
    let mut logs: Vec<&RunLog> = logs.iter().collect();
    logs.sort_by(|a, b| a.name.cmp(&b.name));
    for log in logs {
        let parsed = parse_run(log, config);
        if parsed.run.hardware == Some(false) {
            runs.push(parsed.run);
            continue;
        }
        latencies.extend(parsed.latencies.iter().copied());
        gaps.extend(parsed.read_gaps.iter().copied());
        links.push(link(&log.name, &parsed, config));
        runs.push(parsed.run);
        moves.extend(parsed.moves);
    }
    flag_disturbed(&mut moves, config);
    let groups = groups(&moves);
    let configured = runs
        .iter()
        .rev()
        .filter(|r| r.hardware != Some(false))
        .find_map(|r| r.anti_backlash);
    let recommendations = [Axis::Azimuth, Axis::Altitude]
        .into_iter()
        .map(|axis| Recommendation {
            axis,
            keypad: choose(&groups, axis, |k| {
                matches!(k, Kind::Keypad { rate, .. } if *rate <= config.recommend.max_keypad_rate)
            }),
            timed: choose(&groups, axis, |k| matches!(k, Kind::Timed { .. })),
            configured: configured.map(|a| a[axis.index() * 2]),
        })
        .collect::<Vec<Recommendation>>();
    let preferred = [0, 1].map(|i| {
        recommendations
            .get(i)
            .and_then(|r: &Recommendation| r.keypad.best)
    });
    let applies = applies(&groups, config, preferred);
    let speeds = speeds(&moves);
    let scale = scale(&moves, config);
    let slack_arcsec = [Axis::Azimuth, Axis::Altitude]
        .into_iter()
        .filter_map(|axis| {
            let v: Vec<f64> = groups
                .iter()
                .filter(|g| g.axis == axis && comparable(g))
                .filter_map(|g| g.slack.map(|s| s.value))
                .collect();
            (!v.is_empty()).then(|| (axis, median(&v)))
        })
        .collect();
    latencies.sort_by(f64::total_cmp);
    gaps.sort_by(f64::total_cmp);
    MountAnalysis {
        method: "mount_v1",
        software_version: env!("CARGO_PKG_VERSION"),
        config: config.clone(),
        config_sha256: config_sha256.to_owned(),
        runs,
        moves,
        groups,
        discovery: discovery.map(parse_discovery),
        scale,
        applies,
        slack_arcsec,
        recommendations,
        speeds,
        links,
        latencies_ms: latencies,
        read_gaps_ms: gaps,
    }
}

struct Parsed {
    run: Run,
    moves: Vec<Move>,
    latencies: Vec<f64>,
    failures: usize,
    read_gaps: Vec<f64>,
}

fn parse_run(log: &RunLog, config: &MountConfig) -> Parsed {
    let events: Vec<Value> = log
        .text
        .lines()
        .filter_map(|l| serde_json::from_str(l).ok())
        .collect();
    let t0 = events.iter().find_map(|e| e["t_ns"].as_i64()).unwrap_or(0);
    let mut hardware = None;
    let mut anti_backlash = None;
    let mut positions: Vec<(i64, [f64; 2])> = Vec::new();
    let mut records = Vec::new();
    let mut requests = Vec::new();
    let mut faults = Vec::new();
    let mut notes = Vec::new();
    let mut latencies = Vec::new();
    let mut failures = 0;
    for e in &events {
        let t = e["t_ns"].as_i64().unwrap_or(0);
        match e["event"].as_str().unwrap_or("") {
            "config" => {
                hardware = e["hardware"].as_bool();
                anti_backlash = e["config"]["celestron"]["anti_backlash"]
                    .as_array()
                    .and_then(|a| {
                        let v: Vec<u8> = a
                            .iter()
                            .filter_map(|x| x.as_u64())
                            .map(|x| x as u8)
                            .collect();
                        <[u8; 4]>::try_from(v).ok()
                    });
            }
            "mount_position" => {
                if let Some(d) = e["deg"].as_array()
                    && let (Some(az), Some(alt)) = (
                        d.first().and_then(Value::as_f64),
                        d.get(1).and_then(Value::as_f64),
                    )
                {
                    positions.push((t, [az, alt]));
                }
            }
            "request" => requests.push(e["request"].clone()),
            "record" => records.push(e["record"].clone()),
            "fault" => faults.push(format!(
                "{}: {}",
                e["fault"]["kind"].as_str().unwrap_or("?"),
                e["fault"]["detail"].as_str().unwrap_or("")
            )),
            "operator" => {
                if let Some(text) = e["line"].as_str().and_then(|l| l.strip_prefix("note ")) {
                    notes.push(format!("{:.1} s: {text}", (t - t0) as f64 / 1e9));
                }
            }
            "serial" => {
                if e["outcome"].as_str() == Some("ok") {
                    if let (Some(s), Some(r)) = (e["sent_ns"].as_i64(), e["reply_ns"].as_i64()) {
                        latencies.push((r - s) as f64 / 1e6);
                    }
                } else {
                    failures += 1;
                }
            }
            _ => {}
        }
    }
    positions.sort_by_key(|p| p.0);

    // Commands leave in record order; each move's encoder travel must end
    // before the next one leaves.
    let departures: Vec<i64> = records
        .iter()
        .filter_map(|r| stage(r, "transmitted"))
        .collect();
    let mut last_dir: [Option<i8>; 2] = [None; 2];
    let mut moves = Vec::new();
    let mut incomplete = Vec::new();
    for r in &records {
        let id = r["command_id"].as_u64().unwrap_or(0);
        let last = r["stages"]
            .as_array()
            .and_then(|s| s.last())
            .and_then(|s| s[0].as_str())
            .unwrap_or("")
            .to_owned();
        if !TERMINAL.contains(&last.as_str()) {
            incomplete.push(format!("command {id}: last stage `{last}`"));
        }
        let Some(mut m) = parse_move(&log.name, r, anti_backlash, t0) else {
            continue;
        };
        let i = m.axis.index();
        let tx = stage(r, "transmitted");
        let next = tx.and_then(|tx| departures.iter().copied().find(|&d| d > tx));
        m.encoder_arcsec = match &m.kind {
            Kind::Goto { .. } => goto_travel(r).map(|a| a * f64::from(m.sign)),
            _ => tx
                .and_then(|tx| {
                    let stop = stage(r, "stop_sent").or_else(|| stage(r, "completed"))?;
                    move_travel(
                        &positions,
                        i,
                        tx,
                        stop + (config.settle_s * 1e9) as i64,
                        next,
                    )
                })
                .map(|a| a * f64::from(m.sign)),
        };
        m.history = match last_dir[i] {
            None => History::Unknown,
            Some(d) if d == m.sign => History::Repeat,
            Some(_) => History::Reversal,
        };
        last_dir[i] = (m.outcome == "completed" && m.fault.is_none()).then(|| final_sign(&m, r));
        moves.push(m);
    }
    // Commands in flight, from leaving to their last stage: reads pause then.
    let busy: Vec<(i64, i64)> = records
        .iter()
        .filter_map(|r| {
            let start = stage(r, "requested").or_else(|| stage(r, "transmitted"))?;
            let end = r["stages"].as_array()?.last()?[1].as_i64()?;
            Some((start, end))
        })
        .collect();
    let read_gaps = positions
        .windows(2)
        .filter(|w| !busy.iter().any(|&(a, b)| a < w[1].0 && b > w[0].0))
        .map(|w| (w[1].0 - w[0].0) as f64 / 1e6)
        .collect();
    if requests.len() > records.len() {
        incomplete.push(format!(
            "{} request(s) without a record",
            requests.len() - records.len()
        ));
    }
    let run = Run {
        name: log.name.clone(),
        sha256: crate::hex(&<sha2::Sha256 as sha2::Digest>::digest(log.text.as_bytes())),
        hardware,
        anti_backlash,
        requests: requests.len(),
        records: records.len(),
        moves: moves.len(),
        faults,
        notes,
        incomplete,
    };
    Parsed {
        run,
        moves,
        latencies,
        failures,
        read_gaps,
    }
}

fn stage(record: &Value, name: &str) -> Option<i64> {
    record["stages"]
        .as_array()?
        .iter()
        .find(|s| s[0].as_str() == Some(name))
        .and_then(|s| s[1].as_i64())
}

/// A record's move, or None for a record that isn't one (a stop) or that
/// this method can't read.
fn parse_move(run: &str, r: &Value, anti_backlash: Option<[u8; 4]>, t0: i64) -> Option<Move> {
    let req = &r["request"];
    let (axis, kind, sign) = if let Some(g) = req.get("goto").filter(|g| g.is_object()) {
        let delta = g["delta_deg"].as_f64()?;
        (
            Axis::parse(g["axis"].as_str()?)?,
            Kind::Goto {
                fast: g["speed"].as_str() == Some("fast"),
                delta_deg: delta.abs(),
                approach: !g["approach"].is_null(),
            },
            if delta < 0.0 { -1 } else { 1 },
        )
    } else {
        // Current logs nest moves under `move`; the first ones are flat.
        let m = req.get("move").filter(|m| m.is_object()).unwrap_or(req);
        let duration_ms = m["duration_ms"].as_u64()?;
        let kind = match m["fixed_rate"].as_u64() {
            Some(rate) => Kind::Keypad {
                rate: rate as u8,
                duration_ms,
            },
            None => Kind::Timed {
                rate_deg_s: m["rate_deg_s"].as_f64()?,
                duration_ms,
            },
        };
        let sign = match m["direction"].as_str()? {
            "positive" => 1,
            "negative" => -1,
            _ => return None,
        };
        (Axis::parse(m["axis"].as_str()?)?, kind, sign)
    };
    let tx = stage(r, "transmitted");
    let duration_s = match kind {
        Kind::Goto { .. } => None,
        _ => tx
            .zip(stage(r, "stop_sent"))
            .map(|(a, b)| (b - a) as f64 / 1e9),
    };
    let along = |v: &Value| v.as_f64().map(|d| d * 3600.0 * f64::from(sign));
    let outcome = r["stages"]
        .as_array()
        .and_then(|s| s.last())
        .and_then(|s| s[0].as_str())
        .unwrap_or("")
        .to_owned();
    Some(Move {
        run: run.to_owned(),
        command_id: r["command_id"].as_u64().unwrap_or(0),
        axis,
        kind,
        sign,
        anti_backlash: anti_backlash.map_or(0, |a| a[axis.index() * 2]),
        anti_backlash_assumed: anti_backlash.is_none(),
        t_s: tx.map_or(0.0, |t| (t - t0) as f64 / 1e9),
        duration_s,
        outcome,
        fault: r["fault"].as_str().map(str::to_owned),
        history: History::Unknown,
        commanded_arcsec: along(&r["commanded_deg"]),
        encoder_arcsec: None,
        phone_arcsec: along(&r["observed_deg"]),
        disturbed: false,
    })
}

/// The direction the axis last moved in: a goto with an approach leg ends
/// moving the leg's way.
fn final_sign(m: &Move, r: &Value) -> i8 {
    if let Kind::Goto { approach: true, .. } = m.kind
        && let Some(legs) = r["goto"]["legs"].as_array()
        && let [.., a, b] = legs.as_slice()
        && let (Some(a), Some(b)) = (a.as_i64(), b.as_i64())
    {
        let d = wrap_units(b - a);
        if d != 0 {
            return if d < 0 { -1 } else { 1 };
        }
    }
    m.sign
}

fn wrap_units(d: i64) -> i64 {
    let rev = UNITS_PER_REV as i64;
    (d + rev / 2).rem_euclid(rev) - rev / 2
}

/// A goto's travel (″, signed) from its own start and last positions.
fn goto_travel(r: &Value) -> Option<f64> {
    let g = &r["goto"];
    let (start, last) = (g["start"].as_i64()?, g["last"].as_i64()?);
    Some(wrap_units(last - start) as f64 * ARCSEC_PER_UNIT)
}

/// Encoder travel (″, signed) of a move: the last read before it left to the
/// first read after `after`, which must come before the next command leaves.
fn move_travel(
    positions: &[(i64, [f64; 2])],
    axis: usize,
    tx: i64,
    after: i64,
    next: Option<i64>,
) -> Option<f64> {
    let before = positions.iter().rev().find(|p| p.0 <= tx)?;
    let end = positions
        .iter()
        .find(|p| p.0 >= after && next.is_none_or(|n| p.0 < n))?;
    let d = (end.1[axis] - before.1[axis] + 180.0).rem_euclid(360.0) - 180.0;
    Some(d * 3600.0)
}

/// The groups moves are compared within: axis, kind and size, anti-backlash.
type Key = (Axis, (u8, i64, i64), u8);

fn key(m: &Move) -> Key {
    (m.axis, m.kind.order(), m.anti_backlash)
}

fn flag_disturbed(moves: &mut [Move], config: &MountConfig) {
    let mut classes: BTreeMap<(Key, bool), Vec<usize>> = BTreeMap::new();
    for (i, m) in moves.iter().enumerate() {
        if m.usable() {
            classes
                .entry((key(m), m.history == History::Reversal))
                .or_default()
                .push(i);
        }
    }
    let o = &config.outliers;
    for idx in classes.values() {
        if idx.len() < o.min_moves {
            continue;
        }
        let r: Vec<f64> = idx.iter().filter_map(|&i| moves[i].residual()).collect();
        let med = median(&r);
        let mad = median(&r.iter().map(|v| (v - med).abs()).collect::<Vec<_>>()) * 1.4826;
        for &i in idx {
            let d = (moves[i].residual().unwrap_or(med) - med).abs();
            if d > o.min_arcsec && d > o.robust_k * mad {
                moves[i].disturbed = true;
            }
        }
    }
}

fn median(x: &[f64]) -> f64 {
    let mut v = x.to_vec();
    v.sort_by(f64::total_cmp);
    let n = v.len();
    if n == 0 {
        f64::NAN
    } else if n % 2 == 1 {
        v[n / 2]
    } else {
        (v[n / 2 - 1] + v[n / 2]) / 2.0
    }
}

fn side(moves: &[&Move]) -> Option<Side> {
    let enc: Vec<f64> = moves.iter().filter_map(|m| m.encoder_arcsec).collect();
    let phone: Vec<f64> = moves.iter().filter_map(|m| m.phone_arcsec).collect();
    Some(Side {
        n: moves.len(),
        encoder: Estimate::of(&enc)?,
        phone: Estimate::of(&phone)?,
    })
}

fn groups(moves: &[Move]) -> Vec<Group> {
    let mut by: BTreeMap<Key, Vec<&Move>> = BTreeMap::new();
    for m in moves.iter().filter(|m| m.usable() && !m.disturbed) {
        by.entry(key(m)).or_default().push(m);
    }
    by.into_values()
        .map(|ms| {
            let first = ms[0];
            let rep: Vec<&Move> = ms
                .iter()
                .copied()
                .filter(|m| m.history == History::Repeat)
                .collect();
            let rev: Vec<&Move> = ms
                .iter()
                .copied()
                .filter(|m| m.history == History::Reversal)
                .collect();
            let (repeats, reversals) = (side(&rep), side(&rev));
            let (takeup, over) = match (&repeats, &reversals) {
                (Some(a), Some(b)) => (
                    Some(b.encoder.minus(a.encoder)),
                    Some(b.phone.minus(a.phone)),
                ),
                _ => (None, None),
            };
            let slack = takeup.zip(over).map(|(t, o)| Estimate {
                value: t.value - o.value,
                // Encoder and phone on the same moves aren't independent:
                // use the spread of each move's phone − encoder instead.
                se: residual_se(&rep, &rev),
            });
            let mut runs: Vec<String> = ms.iter().map(|m| m.run.clone()).collect();
            runs.dedup();
            Group {
                axis: first.axis,
                kind: first.kind.clone(),
                label: first.kind.label(),
                anti_backlash: first.anti_backlash,
                repeats,
                reversals,
                takeup,
                over_correction: over,
                slack,
                runs,
            }
        })
        .collect()
}

fn parse_discovery(d: &DiscoveryLog) -> Discovery {
    let v: Value = serde_json::from_str(&d.text).unwrap_or(Value::Null);
    let value = |query: &str| {
        v["exchanges"]
            .as_array()
            .and_then(|x| x.iter().find(|e| e["query"].as_str() == Some(query)))
    };
    let backlash = [
        "azimuth backlash, positive",
        "azimuth backlash, negative",
        "altitude backlash, positive",
        "altitude backlash, negative",
    ]
    .iter()
    .map(|q| {
        value(q)
            .and_then(|e| e["value"]["backlash"].as_u64())
            .map(|b| b as u8)
    })
    .collect::<Option<Vec<u8>>>()
    .and_then(|b| <[u8; 4]>::try_from(b).ok());
    let approach = |q: &str| {
        value(q)
            .and_then(|e| e["value"]["approach"].as_str())
            .map(str::to_owned)
    };
    let text = |x: &Value| x.as_str().map(str::to_owned);
    let usb = &v["connection"]["usb"];
    Discovery {
        name: d.name.clone(),
        sha256: crate::hex(&<sha2::Sha256 as sha2::Digest>::digest(d.text.as_bytes())),
        simulated: v["simulated"].as_bool().unwrap_or(false),
        model: text(&v["identity"]["model"]),
        hand_controller: text(&v["identity"]["controller_version"]),
        motors: v["identity"]["motor_versions"]
            .as_array()
            .map(|m| {
                m.iter()
                    .filter_map(|x| x.as_str().map(str::to_owned))
                    .collect()
            })
            .unwrap_or_default(),
        usb: match (usb["manufacturer"].as_str(), usb["product"].as_str()) {
            (Some(m), Some(p)) => Some(format!("{m} {p}")),
            (None, Some(p)) => Some(p.to_owned()),
            _ => None,
        },
        link: text(&v["connection"]["settings"]),
        anti_backlash: backlash,
        approach: [
            approach("azimuth goto approach"),
            approach("altitude goto approach"),
        ],
        azimuth_index: value("azimuth at index marker?").map(|e| {
            match (e["outcome"].as_str(), e["value"]["flag"].as_bool()) {
                (Some("ok"), Some(true)) => "at the marker".to_owned(),
                (Some("ok"), Some(false)) => "answers: not at the marker".to_owned(),
                _ => "no answer".to_owned(),
            }
        }),
        position_reply_ms: v["position_latency"]["median_ms"].as_f64(),
    }
}

/// The phone's travel over the encoder's on one-way moves long enough that
/// the phone's scatter is small: checks the encoder scale.
fn scale(moves: &[Move], config: &MountConfig) -> Vec<ScaleCheck> {
    [Axis::Azimuth, Axis::Altitude]
        .into_iter()
        .filter_map(|axis| {
            let ratios: Vec<f64> = moves
                .iter()
                .filter(|m| {
                    m.axis == axis
                        && m.usable()
                        && !m.disturbed
                        && m.history == History::Repeat
                        && m.encoder_arcsec
                            .is_some_and(|e| e >= config.scale.min_travel_arcsec)
                })
                .filter_map(|m| Some(m.phone_arcsec? / m.encoder_arcsec?))
                .collect();
            Some(ScaleCheck {
                axis,
                moves: ratios.len(),
                ratio: Estimate::of(&ratios)?,
            })
        })
        .collect()
}

/// Whether anti-backlash acts on each kind of command: its take-up at a
/// non-zero setting (the axis's recommended one if it was measured there,
/// else the most-measured one). A keypad rate above the fine
/// rates acts "partly" when its take-up is under 80% of the fine rates' at
/// the same setting.
fn applies(groups: &[Group], config: &MountConfig, preferred: [Option<u8>; 2]) -> Vec<Applies> {
    let family = |k: &Kind| match k {
        Kind::Keypad { rate, .. } => format!("keypad r{rate}"),
        Kind::Timed { .. } => "timed".into(),
        Kind::Goto { fast, .. } => format!("goto {}", if *fast { "fast" } else { "slow" }),
    };
    let max = config.recommend.max_keypad_rate;
    let mut best: BTreeMap<(Axis, (u8, i64), String), &Group> = BTreeMap::new();
    for g in groups
        .iter()
        .filter(|g| g.anti_backlash > 0 && comparable(g) && g.takeup.is_some())
        .filter(|g| !matches!(g.kind, Kind::Goto { approach: true, .. }))
    {
        let order = match g.kind {
            Kind::Keypad { rate, .. } => (0, i64::from(rate)),
            Kind::Timed { .. } => (1, 0),
            Kind::Goto { fast, .. } => (2, i64::from(fast)),
        };
        let n = |g: &Group| g.reversals.as_ref().map_or(0, |s| s.n);
        best.entry((g.axis, order, family(&g.kind)))
            .and_modify(|old| {
                let rank = |g: &Group| {
                    (
                        preferred[g.axis.index()] == Some(g.anti_backlash),
                        n(g),
                        g.anti_backlash,
                    )
                };
                if rank(g) > rank(old) {
                    *old = g;
                }
            })
            .or_insert(g);
    }
    best.into_iter()
        .map(|((axis, _, commands), g)| {
            let t = g.takeup.expect("filtered");
            let noise = (2.0 * t.se.unwrap_or(0.0)).max(20.0);
            let fine: Vec<f64> = groups
                .iter()
                .filter(|h| {
                    h.axis == axis
                        && h.anti_backlash == g.anti_backlash
                        && comparable(h)
                        && matches!(h.kind, Kind::Keypad { rate, .. } if rate <= max)
                })
                .filter_map(|h| h.takeup.map(|e| e.value))
                .collect();
            let acts = if t.value <= noise {
                Acts::No
            } else if matches!(g.kind, Kind::Keypad { rate, .. } if rate > max)
                && !fine.is_empty()
                && t.value < 0.8 * median(&fine)
            {
                Acts::Partly
            } else {
                Acts::Yes
            };
            Applies {
                axis,
                commands,
                acts,
                anti_backlash: g.anti_backlash,
                takeup: t,
            }
        })
        .collect()
}

/// A group counts towards a choice with at least two repeats and reversals.
pub fn comparable(g: &Group) -> bool {
    g.repeats.as_ref().is_some_and(|s| s.n >= 2) && g.reversals.as_ref().is_some_and(|s| s.n >= 2)
}

/// The setting where the family's reversals over-correct least on average,
/// among the settings where every move type in it (those tried at two or
/// more settings) was tried.
fn choose(groups: &[Group], axis: Axis, family: impl Fn(&Kind) -> bool) -> Choice {
    let members: Vec<&Group> = groups
        .iter()
        .filter(|g| {
            g.axis == axis && family(&g.kind) && comparable(g) && g.over_correction.is_some()
        })
        .collect();
    let mut kinds: Vec<String> = Vec::new();
    for g in &members {
        let settings = members.iter().filter(|h| h.label == g.label).count();
        if settings > 1 && !kinds.contains(&g.label) {
            kinds.push(g.label.clone());
        }
    }
    let mut settings: Vec<u8> = members.iter().map(|g| g.anti_backlash).collect();
    settings.sort_unstable();
    settings.dedup();
    let mut scores: Vec<Score> = settings
        .into_iter()
        .filter_map(|ab| {
            let over: Vec<f64> = kinds
                .iter()
                .map(|k| {
                    members
                        .iter()
                        .find(|g| &g.label == k && g.anti_backlash == ab)
                        .and_then(|g| g.over_correction)
                        .map(|e| e.value.abs())
                })
                .collect::<Option<_>>()?;
            (!over.is_empty()).then(|| Score {
                anti_backlash: ab,
                mean_abs_over_correction: over.iter().sum::<f64>() / over.len() as f64,
                kinds: over.len(),
            })
        })
        .collect();
    scores.sort_by(|a, b| {
        a.mean_abs_over_correction
            .total_cmp(&b.mean_abs_over_correction)
            .then(a.anti_backlash.cmp(&b.anti_backlash))
    });
    Choice {
        kinds,
        best: scores.first().map(|s| s.anti_backlash),
        scores,
    }
}

fn residual_se(rep: &[&Move], rev: &[&Move]) -> Option<f64> {
    let a: Vec<f64> = rep.iter().filter_map(|m| m.residual()).collect();
    let b: Vec<f64> = rev.iter().filter_map(|m| m.residual()).collect();
    Estimate::of(&a)?.minus(Estimate::of(&b)?).se
}

fn speeds(moves: &[Move]) -> Vec<Speed> {
    let mut by: BTreeMap<(Axis, u8), Vec<f64>> = BTreeMap::new();
    for m in moves {
        if let Kind::Keypad { rate, .. } = m.kind
            && m.history == History::Repeat
            && m.fault.is_none()
            && m.outcome == "completed"
            && let (Some(enc), Some(d)) = (m.encoder_arcsec, m.duration_s)
            && d > 0.0
        {
            by.entry((m.axis, rate)).or_default().push(enc / 3600.0 / d);
        }
    }
    by.into_iter()
        .map(|((axis, rate), v)| Speed {
            axis,
            rate,
            n: v.len(),
            median_deg_s: median(&v),
            celestron_deg_s: CELESTRON_RATES_DEG_S[usize::from(rate.clamp(1, 9)) - 1],
        })
        .collect()
}

fn link(run: &str, p: &Parsed, config: &MountConfig) -> Link {
    let sorted = |x: &[f64]| {
        let mut v = x.to_vec();
        v.sort_by(f64::total_cmp);
        v
    };
    let (lat, gaps) = (sorted(&p.latencies), sorted(&p.read_gaps));
    let at = |v: &[f64], q: f64| (!v.is_empty()).then(|| crate::math::percentile(v, q));
    Link {
        run: run.to_owned(),
        exchanges: lat.len() + p.failures,
        failures: p.failures,
        median_ms: at(&lat, 50.0),
        p95_ms: at(&lat, 95.0),
        max_ms: lat.last().copied(),
        stalls: lat.iter().filter(|&&l| l > config.link.stall_ms).count(),
        read_gaps: gaps.len(),
        read_gap_median_ms: at(&gaps, 50.0),
        read_gap_p95_ms: at(&gaps, 95.0),
        read_gap_max_ms: gaps.last().copied(),
        read_stalls: gaps
            .iter()
            .filter(|&&g| g > config.link.read_stall_ms)
            .count(),
    }
}
