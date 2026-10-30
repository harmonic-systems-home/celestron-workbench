//! Runs the query plan through a hand controller, records every exchange
//! byte for byte, and derives the checks for the compatibility report.

use std::time::{Duration, Instant};

use cwb_mount_core::{MountIdentity, MountQueries, SafetyConfig, TransportError};
use serde::Serialize;

use crate::{
    link::{self, Link, UsbInfo},
    query::{self, Device, EVOLUTION_MODEL, Query, Sense, Value},
};

pub use crate::link::Outcome;

#[derive(Debug, Clone, Serialize)]
pub struct Exchange {
    pub index: usize,
    pub query: String,
    pub reference: &'static str,
    pub sent_hex: String,
    pub received_hex: String,
    pub outcome: Outcome,
    pub value: Option<Value>,
    /// From the start of the run.
    pub started_ms: f64,
    pub latency_ms: f64,
    #[serde(skip)]
    pub kind: Option<Query>,
}

/// A hand controller behind a byte link. Only [`Query`]s can be sent.
pub struct HandController<L: Link> {
    link: L,
    start: Instant,
    exchanges: Vec<Exchange>,
}

impl<L: Link> HandController<L> {
    pub fn new(link: L) -> Self {
        Self {
            link,
            start: Instant::now(),
            exchanges: Vec::new(),
        }
    }

    pub fn exchanges(&self) -> &[Exchange] {
        &self.exchanges
    }

    /// The link, for crates that send their own commands between queries
    /// (setup, motion). Discovery itself never uses it.
    pub fn link_mut(&mut self) -> &mut L {
        &mut self.link
    }

    pub fn into_parts(self) -> (L, Vec<Exchange>) {
        (self.link, self.exchanges)
    }

    pub fn query(&mut self, q: Query) -> &Exchange {
        let sent = q.bytes();
        let started = self.start.elapsed();
        let t0 = Instant::now();
        let (mut outcome, received) =
            link::transact(&mut self.link, &sent, q.reply_len(), q.is_pass_through());
        let latency = t0.elapsed();
        let value = if outcome == Outcome::Ok {
            q.decode(&received[..q.reply_len()])
        } else {
            None
        };
        if outcome == Outcome::Ok && value.is_none() {
            outcome = Outcome::Malformed;
        }
        self.exchanges.push(Exchange {
            index: self.exchanges.len(),
            query: q.to_string(),
            reference: q.reference(),
            sent_hex: hex(&sent),
            received_hex: hex(&received),
            outcome,
            value,
            started_ms: ms(started),
            latency_ms: ms(latency),
            kind: Some(q),
        });
        self.exchanges.last().expect("just pushed")
    }
}

impl<L: Link> MountQueries for HandController<L> {
    fn identify(&mut self) -> Result<MountIdentity, TransportError> {
        let start = self.exchanges.len();
        for q in [
            Query::Version,
            Query::Model,
            Query::DeviceVersion(Device::AzmMotor),
            Query::DeviceVersion(Device::AltMotor),
        ] {
            self.query(q);
        }
        let identity = identity(&self.exchanges[start..]);
        if identity.controller_version.is_none() {
            return Err(TransportError("the hand controller did not answer".into()));
        }
        Ok(identity)
    }

    fn axis_positions_deg(&mut self) -> Result<[f64; 2], TransportError> {
        let e = self.query(Query::PreciseAzmAlt);
        match e.value {
            Some(Value::Angles {
                azm_deg, alt_deg, ..
            }) => Ok([azm_deg, alt_deg]),
            _ => Err(TransportError(format!(
                "position query failed: {:?}",
                e.outcome
            ))),
        }
    }
}

/// The identity reported by the most recent answers in `exchanges`.
pub fn identity(exchanges: &[Exchange]) -> MountIdentity {
    let latest = |want: Query| {
        exchanges
            .iter()
            .rev()
            .find(|e| e.kind == Some(want) && e.value.is_some())
            .and_then(|e| e.value.clone())
    };
    MountIdentity {
        controller_version: latest(Query::Version).map(|v| v.to_string()),
        model: latest(Query::Model).map(|v| v.to_string()),
        motor_versions: [Device::AzmMotor, Device::AltMotor]
            .map(|d| latest(Query::DeviceVersion(d)).map(|v| v.to_string())),
    }
}

/// Operator-supplied facts the protocol can't report.
#[derive(Debug, Clone, Default, Serialize)]
pub struct OperatorInfo {
    pub mount: Option<String>,
    pub hand_controller: Option<String>,
    pub hand_controller_firmware: Option<String>,
    pub cable: Option<String>,
    pub notes: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
pub struct Connection {
    /// Redacted: USB device names carry serial numbers.
    pub port: String,
    pub usb: Option<UsbInfo>,
    pub settings: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Status {
    Pass,
    Warn,
    Fail,
    Info,
}

#[derive(Debug, Clone, Serialize)]
pub struct Check {
    pub name: &'static str,
    pub status: Status,
    pub detail: String,
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct Stats {
    pub count: usize,
    pub median_ms: f64,
    pub max_ms: f64,
}

#[derive(Debug, Clone, Serialize)]
pub struct Discovery {
    pub simulated: bool,
    pub generated_utc: String,
    pub tool_version: &'static str,
    pub operator: OperatorInfo,
    pub connection: Connection,
    pub identity: MountIdentity,
    pub checks: Vec<Check>,
    /// Precise position replies: spread of azimuth and altitude, arcseconds.
    pub position_spread_arcsec: Option<[f64; 2]>,
    pub position_latency: Stats,
    pub echo_latency: Stats,
    pub exchanges: Vec<Exchange>,
}

impl Discovery {
    pub fn ready(&self) -> bool {
        !self.checks.iter().any(|c| c.status == Status::Fail)
    }
}

/// Runs the whole plan; never stops early, so the trace shows everything.
pub fn discover<L: Link>(hc: &mut HandController<L>, repeats: usize) {
    for q in query::plan(repeats) {
        hc.query(q);
    }
}

pub fn summarize(
    exchanges: Vec<Exchange>,
    simulated: bool,
    generated_utc: String,
    operator: OperatorInfo,
    connection: Connection,
) -> Discovery {
    let ok = |q: Query| -> Vec<&Exchange> {
        exchanges
            .iter()
            .filter(|e| e.kind == Some(q) && e.outcome == Outcome::Ok)
            .collect()
    };
    let value = |q: Query| ok(q).last().and_then(|e| e.value.clone());
    let mut checks = Vec::new();
    let mut check = |name, status, detail: String| {
        checks.push(Check {
            name,
            status,
            detail,
        })
    };

    let echoes: Vec<&Exchange> = exchanges
        .iter()
        .filter(|e| matches!(e.kind, Some(Query::Echo(_))))
        .collect();
    let echoed = echoes.iter().all(|e| match (e.kind, &e.value) {
        (Some(Query::Echo(x)), Some(Value::Echo(y))) => x == *y,
        _ => false,
    });
    if !echoes.is_empty() && echoed {
        check(
            "Link",
            Status::Pass,
            format!("all {} echoes returned the byte sent", echoes.len()),
        );
    } else {
        check("Link", Status::Fail, "echo failed: check the port, cable and that the hand controller has finished starting up".into());
    }

    // The 2.2 threshold is the 2006 document's numbering. Later hand
    // controllers number their firmware differently, so what they answer
    // decides, not the number.
    let answers_2_2_queries = value(Query::Model).is_some() && !ok(Query::PreciseAzmAlt).is_empty();
    match value(Query::Version) {
        Some(Value::Version { major, minor }) if (major, minor) >= (2, 2) => check(
            "Hand controller version",
            Status::Pass,
            format!("{major}.{minor}: precise positions and model query are documented from 2.2"),
        ),
        Some(v) if answers_2_2_queries => check(
            "Hand controller version",
            Status::Info,
            format!(
                "{v}: below the document's 2.2, but this hand controller answers the model and precise position queries, so its numbering doesn't follow the 2006 document"
            ),
        ),
        Some(v) => check(
            "Hand controller version",
            Status::Fail,
            format!("{v}: below 2.2, the precise position query isn't available"),
        ),
        None => check("Hand controller version", Status::Fail, "no answer".into()),
    }

    match value(Query::Model) {
        Some(Value::Model(EVOLUTION_MODEL)) => check(
            "Model",
            Status::Pass,
            format!(
                "{EVOLUTION_MODEL}, NexStar Evolution (code from libnexstar; Celestron's table stops at 12)"
            ),
        ),
        Some(v) => check(
            "Model",
            Status::Warn,
            format!("{v}: not the NexStar Evolution this project assumes"),
        ),
        None => check("Model", Status::Fail, "no answer".into()),
    }

    let motors: Vec<String> = [
        ("azimuth", Device::AzmMotor),
        ("altitude", Device::AltMotor),
    ]
    .iter()
    .map(|(name, d)| match value(Query::DeviceVersion(*d)) {
        Some(v) => format!("{name} {v}"),
        None => format!("{name} did not answer"),
    })
    .collect();
    let both = [Device::AzmMotor, Device::AltMotor]
        .iter()
        .all(|d| value(Query::DeviceVersion(*d)).is_some());
    check(
        "Motor controllers",
        if both { Status::Pass } else { Status::Fail },
        motors.join("; "),
    );

    let backlash: Vec<(String, Option<u8>)> = [
        ("azimuth +", Device::AzmMotor, Sense::Positive),
        ("azimuth −", Device::AzmMotor, Sense::Negative),
        ("altitude +", Device::AltMotor, Sense::Positive),
        ("altitude −", Device::AltMotor, Sense::Negative),
    ]
    .into_iter()
    .map(|(name, d, sense)| {
        let v = match value(Query::Backlash(d, sense)) {
            Some(Value::Backlash(v)) => Some(v),
            _ => None,
        };
        (name.to_owned(), v)
    })
    .collect();
    let listed = backlash
        .iter()
        .map(|(n, v)| format!("{n} {}", v.map_or("—".into(), |v| v.to_string())))
        .collect::<Vec<_>>()
        .join(", ");
    if backlash.iter().any(|(_, v)| v.is_none()) {
        check(
            "Anti-backlash",
            Status::Warn,
            format!(
                "{listed}: not every value was read (the query is from libnexstar, not Celestron's document)"
            ),
        );
    } else if backlash.iter().all(|(_, v)| *v == Some(0)) {
        check(
            "Anti-backlash",
            Status::Pass,
            format!("{listed}: no compensation"),
        );
    } else {
        check(
            "Anti-backlash",
            Status::Warn,
            format!(
                "{listed}: compensation on a reversal would hide the backlash being measured; set to 0 for characterization"
            ),
        );
    }

    match value(Query::GotoInProgress) {
        Some(Value::Flag(false)) => check("Goto in progress", Status::Pass, "no".into()),
        Some(_) => check(
            "Goto in progress",
            Status::Warn,
            "yes: wait for it to finish before any test".into(),
        ),
        None => check("Goto in progress", Status::Fail, "no answer".into()),
    }

    match value(Query::TrackingMode) {
        Some(Value::TrackingMode(0)) => check("Tracking", Status::Pass, "off".into()),
        Some(v) => check(
            "Tracking",
            Status::Warn,
            format!(
                "{v}: slews conflict with tracking, so the adapter must turn it off first (Set Tracking Mode 0)"
            ),
        ),
        None => check("Tracking", Status::Fail, "no answer".into()),
    }

    match value(Query::AlignmentComplete) {
        Some(Value::Flag(true)) => check("Alignment", Status::Info, "aligned: azimuth is indexed to north".into()),
        Some(_) => check("Alignment", Status::Info, "not aligned: axis angles are relative to where the mount was powered on, which is all the tests need".into()),
        None => check("Alignment", Status::Fail, "no answer".into()),
    }

    let readings: Vec<[u32; 2]> = ok(Query::PreciseAzmAlt)
        .iter()
        .filter_map(|e| match e.value {
            Some(Value::Angles { raw, .. }) => Some(raw),
            _ => None,
        })
        .collect();
    let spread = (!readings.is_empty()).then(|| {
        [0, 1].map(|axis| {
            // Relative to the first reading, so a wrap through 0° is harmless.
            let rel: Vec<i64> = readings
                .iter()
                .map(|r| i64::from(r[axis].wrapping_sub(readings[0][axis]) as i32))
                .collect();
            let span = rel.iter().max().unwrap() - rel.iter().min().unwrap();
            span as f64 / 2f64.powi(32) * 360.0 * 3_600.0
        })
    });
    let precise_sent = exchanges
        .iter()
        .filter(|e| e.kind == Some(Query::PreciseAzmAlt))
        .count();
    if precise_sent > 0 && readings.len() == precise_sent {
        check(
            "Axis positions",
            Status::Pass,
            format!(
                "{} precise readings, last {}",
                readings.len(),
                value(Query::PreciseAzmAlt).unwrap()
            ),
        );
    } else {
        check(
            "Axis positions",
            Status::Fail,
            format!(
                "{} of {precise_sent} precise readings answered",
                readings.len()
            ),
        );
    }
    if let Some([azm, alt]) = spread {
        let steady = azm.max(alt) <= 30.0;
        check(
            "Positions steady",
            if steady { Status::Pass } else { Status::Warn },
            format!(
                "spread azimuth {azm:.2}″, altitude {alt:.2}″ (one unit of the 24 bits used is 0.077″){}",
                if steady {
                    ""
                } else {
                    ": the mount moved during discovery, or the encoders are noisy"
                }
            ),
        );
    }

    // The motor controllers' own positions, which a goto by pass-through
    // targets, against the hand controller's (upper 24 bits of `z`).
    let axes = [
        ("azimuth", Device::AzmMotor),
        ("altitude", Device::AltMotor),
    ];
    let motor: Vec<Option<u32>> = axes
        .iter()
        .map(|(_, d)| match value(Query::MotorPosition(*d)) {
            Some(Value::MotorPosition { units, .. }) => Some(units),
            _ => None,
        })
        .collect();
    if motor.iter().any(Option::is_none) {
        check(
            "Motor positions",
            Status::Warn,
            "not every motor controller answered (the query is from the community-documented AUX command set): gotos by motor position can't be used".into(),
        );
    } else {
        let listed: Vec<String> = axes
            .iter()
            .zip(&motor)
            .map(|((name, _), units)| format!("{name} {}", units.unwrap()))
            .collect();
        let differences = readings.first().map(|first| {
            [0, 1].map(|axis| {
                // Signed, so a wrap through 0° reads as a small difference.
                let hc = first[axis] >> 8;
                ((motor[axis].unwrap().wrapping_sub(hc) << 8) as i32) >> 8
            })
        });
        match differences {
            Some(d) if d.iter().all(|x| x.abs() <= 2) => check(
                "Motor positions",
                Status::Pass,
                format!(
                    "{} (24 bits per revolution): the same as the hand controller's precise positions",
                    listed.join(", ")
                ),
            ),
            Some([azm, alt]) => check(
                "Motor positions",
                Status::Info,
                format!(
                    "{}: the hand controller's precise positions differ by azimuth {azm:+}, altitude {alt:+} units, so it applies an offset; gotos must use the motor controllers' own positions",
                    listed.join(", ")
                ),
            ),
            None => check(
                "Motor positions",
                Status::Info,
                format!("{} (no precise positions to compare)", listed.join(", ")),
            ),
        }
    }
    let done: Vec<Option<Value>> = axes
        .iter()
        .map(|(_, d)| value(Query::SlewDone(*d)))
        .collect();
    let named = |v: &Option<Value>| match v {
        Some(Value::Flag(true)) => "done",
        Some(_) => "in progress",
        None => "no answer",
    };
    let listed = format!("azimuth {}, altitude {}", named(&done[0]), named(&done[1]));
    if done.iter().all(|v| *v == Some(Value::Flag(true))) {
        check("Slew done", Status::Pass, listed);
    } else if done.iter().any(Option::is_none) {
        check(
            "Slew done",
            Status::Warn,
            format!(
                "{listed} (the query is from the community-documented AUX command set): a goto's end can't be detected"
            ),
        );
    } else {
        check(
            "Slew done",
            Status::Warn,
            format!("{listed}: a motor controller reports a goto still running"),
        );
    }

    let position_latency = latency(&ok(Query::PreciseAzmAlt));
    let echo_latency = latency(
        &exchanges
            .iter()
            .filter(|e| matches!(e.kind, Some(Query::Echo(_))) && e.outcome == Outcome::Ok)
            .collect::<Vec<_>>(),
    );
    let ack_ms = SafetyConfig::default().ack_deadline_ms as f64;
    if position_latency.count > 0 {
        let within = position_latency.max_ms <= ack_ms;
        check(
            "Reply latency",
            if within { Status::Pass } else { Status::Warn },
            format!(
                "position via the motors: median {:.1} ms, max {:.1} ms; echo: median {:.1} ms, max {:.1} ms. {}",
                position_latency.median_ms,
                position_latency.max_ms,
                echo_latency.median_ms,
                echo_latency.max_ms,
                if within {
                    format!("Within the {ack_ms:.0} ms acknowledgement deadline.")
                } else {
                    format!(
                        "Some replies exceed the {ack_ms:.0} ms acknowledgement deadline: review it before motion tests."
                    )
                }
            ),
        );
    }

    let failed: Vec<String> = exchanges
        .iter()
        .filter(|e| e.outcome != Outcome::Ok)
        .map(|e| format!("#{} {} ({:?})", e.index, e.query, e.outcome))
        .collect();
    check(
        "All queries answered",
        if failed.is_empty() {
            Status::Pass
        } else {
            Status::Fail
        },
        if failed.is_empty() {
            format!("{} of {}", exchanges.len(), exchanges.len())
        } else {
            failed.join(", ")
        },
    );

    Discovery {
        simulated,
        generated_utc,
        tool_version: env!("CARGO_PKG_VERSION"),
        operator,
        connection,
        identity: identity(&exchanges),
        checks,
        position_spread_arcsec: spread,
        position_latency,
        echo_latency,
        exchanges,
    }
}

fn latency(exchanges: &[&Exchange]) -> Stats {
    let mut v: Vec<f64> = exchanges.iter().map(|e| e.latency_ms).collect();
    if v.is_empty() {
        return Stats::default();
    }
    v.sort_by(f64::total_cmp);
    Stats {
        count: v.len(),
        median_ms: v[v.len() / 2],
        max_ms: v[v.len() - 1],
    }
}

pub fn hex(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect::<Vec<_>>()
        .join(" ")
}

fn ms(d: Duration) -> f64 {
    d.as_secs_f64() * 1e3
}
