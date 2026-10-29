//! The interactive mount test runner's core (plan Prompt 8, ADR 0013).
//!
//! [`Runner`] wires the interlock [`Controller`] to a mount adapter and the
//! live IMU: phone messages arrive through the receiver's tap, are put on
//! the Mac clock with a live clock model and turned into mount-axis terms,
//! and drive the controller's checks. The operator types one line at a
//! time; an empty line is always Stop. Everything is written to a run log.
//!
//! The core does no terminal or network I/O and takes the time as an
//! argument, so it is tested with the simulated mount.

pub mod clock;
pub mod config;
pub mod log;

use std::collections::HashSet;

use cwb_mount_celestron::{CelestronAdapter, Position, encode::quantized_deg_s};
use cwb_mount_core::{
    Action, Axis, Controller, Direction, FaultKind, MountAdapter, MountReport, MountState,
    MoveRequest, Nanos, Observation, imu::AxisMapper,
};
use cwb_mount_sim::SimMount;
use cwb_protocol::{Message, Sample};
use cwb_receiver::Tapped;
use serde_json::json;

pub use clock::LiveClock;
pub use config::RunnerConfig;
pub use log::RunLog;

const MS: Nanos = 1_000_000;

/// What the runner needs from a mount adapter beyond [`MountAdapter`].
pub trait RunnerAdapter: MountAdapter {
    /// The mount's own axis positions read since the last call.
    fn take_positions(&mut self) -> Vec<Position> {
        Vec::new()
    }
    fn take_notes(&mut self) -> Vec<String> {
        Vec::new()
    }
}

impl RunnerAdapter for CelestronAdapter {
    fn take_positions(&mut self) -> Vec<Position> {
        CelestronAdapter::take_positions(self)
    }
    fn take_notes(&mut self) -> Vec<String> {
        CelestronAdapter::take_notes(self)
    }
}

impl RunnerAdapter for SimMount {}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Info,
    /// Needs the operator's attention now.
    Alert,
    /// Waiting for the operator's answer.
    Prompt,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Out {
    pub kind: Kind,
    pub text: String,
}

fn info(text: impl Into<String>) -> Out {
    Out {
        kind: Kind::Info,
        text: text.into(),
    }
}

fn alert(text: impl Into<String>) -> Out {
    Out {
        kind: Kind::Alert,
        text: text.into(),
    }
}

fn prompt(text: impl Into<String>) -> Out {
    Out {
        kind: Kind::Prompt,
        text: text.into(),
    }
}

/// The mount-session checklist (docs/plan.md), confirmed before connecting.
pub const CHECKLIST: &[&str] = &[
    "Balance, clamps, tripod stability and the phone's strap and holder are secure.",
    "The tube, phone, strap and cables clear the fork and base through the motion you'll test.",
    "The mount, hand controller, firmware and USB link match the approved discovery report.",
    "config/mount.toml is reviewed: axis signs, tube axis, rate cap and duration cap.",
    "You are within reach of the mount's power switch, and it stops the mount with this program dead.",
    "The hand controller is at its top-level screen; hands stay off its arrow keys during runs.",
    "The phone is recording to this Mac (the runner will show the IMU as fresh).",
];

pub const HELP: &str = "\
Enter (empty line)  STOP: ends any move at once
arm | disarm        allow moves | refuse them
az+ az- alt+ alt-   move one axis: [rate °/s] [seconds], e.g. `az+ 0.1 1`
status              state, IMU, travel and mount positions
reset               clear a fault once the mount is still
e                   emergency stop (latches a fault)
quit                stop everything and exit";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Stage {
    Checklist,
    Ready,
    Done,
}

pub struct Runner<A: RunnerAdapter> {
    controller: Controller,
    adapter: A,
    config: RunnerConfig,
    mapper: AxisMapper,
    clock: LiveClock,
    log: RunLog,
    /// Moves on real hardware need confirming the first time per axis and direction.
    hardware: bool,
    stage: Stage,
    pending: Option<MoveRequest>,
    confirmed: HashSet<(Axis, Direction)>,
    next_request: u64,
    session: Option<String>,
    last_state: MountState,
    faults_seen: usize,
    records_seen: usize,
    last_observation: Option<Observation>,
    last_position: Option<Position>,
}

impl<A: RunnerAdapter> Runner<A> {
    /// Starts at the checklist. `mac_clock_boot_id` names this Mac clock
    /// domain: only clock exchanges answered by it are used.
    pub fn new(
        config: RunnerConfig,
        adapter: A,
        mut log: RunLog,
        hardware: bool,
        mac_clock_boot_id: &str,
        now: Nanos,
    ) -> Result<(Self, Vec<Out>), String> {
        let mapper = AxisMapper::new(config.tube()?)?;
        let controller = Controller::new(config.safety.clone()).map_err(|p| p.join("; "))?;
        log.write(
            now,
            "config",
            json!({ "config": config, "hardware": hardware }),
        );
        let runner = Self {
            controller,
            adapter,
            mapper,
            clock: LiveClock::new(mac_clock_boot_id),
            log,
            hardware,
            stage: Stage::Checklist,
            pending: None,
            confirmed: HashSet::new(),
            next_request: 1,
            session: None,
            last_state: MountState::Disconnected,
            faults_seen: 0,
            records_seen: 0,
            last_observation: None,
            last_position: None,
            config,
        };
        let mut out = vec![info("Mount-session checklist:")];
        out.extend(CHECKLIST.iter().map(|c| info(format!("  - {c}"))));
        out.push(prompt(
            "Type yes when every item holds. Moves stay disabled until then.",
        ));
        Ok((runner, out))
    }

    pub fn state(&self) -> MountState {
        self.controller.state()
    }

    pub fn finished(&self) -> bool {
        self.stage == Stage::Done
    }

    pub fn controller(&self) -> &Controller {
        &self.controller
    }

    pub fn adapter(&self) -> &A {
        &self.adapter
    }

    /// For simulation: the caller steps the simulated mount's physics.
    pub fn adapter_mut(&mut self) -> &mut A {
        &mut self.adapter
    }

    /// One line from the operator.
    pub fn line(&mut self, text: &str, now: Nanos) -> Vec<Out> {
        let text = text.trim();
        self.log.write(now, "operator", json!({ "line": text }));
        let mut out = Vec::new();
        if text.is_empty() {
            self.pending = None;
            let actions = self.controller.stop(now);
            self.carry_out(actions, now, &mut out);
            out.push(alert("STOP sent"));
            return out;
        }
        let words: Vec<&str> = text.split_whitespace().collect();
        match (self.stage, words[0]) {
            (Stage::Done, _) => {}
            (_, "quit" | "q") => out.extend(self.quit(now)),
            (_, "help" | "h" | "?") => out.push(info(HELP)),
            (_, "e" | "estop") => {
                let actions = self.controller.emergency_stop(now);
                self.carry_out(actions, now, &mut out);
            }
            (Stage::Checklist, "yes") => {
                self.stage = Stage::Ready;
                self.log
                    .write(now, "checklist", json!({ "confirmed": CHECKLIST }));
                let result = self.controller.connect(now);
                self.result(result, now, &mut out);
                out.push(info(
                    "Checklist confirmed. Wait for the IMU to show fresh (status), then arm. Type help for commands.",
                ));
            }
            (Stage::Checklist, _) => out.push(prompt(
                "Confirm the checklist first: type yes when every item holds.",
            )),
            (Stage::Ready, "yes") => match self.pending.take() {
                Some(request) => {
                    self.confirmed.insert((request.axis, request.direction));
                    self.request(request, now, &mut out);
                }
                None => out.push(info("Nothing to confirm.")),
            },
            (Stage::Ready, "arm") => {
                let result = self.controller.arm(now);
                self.result(result, now, &mut out);
            }
            (Stage::Ready, "disarm") => {
                let result = self.controller.disarm(now);
                self.result(result, now, &mut out);
            }
            (Stage::Ready, "reset") => {
                let result = self.controller.reset(now);
                self.result(result, now, &mut out);
            }
            (Stage::Ready, "status" | "s") => out.push(info(self.status(now))),
            (Stage::Ready, word) => match self.parse_move(word, &words[1..]) {
                Ok(request) => {
                    self.pending = None;
                    if self.hardware && !self.confirmed.contains(&(request.axis, request.direction))
                    {
                        out.push(prompt(format!(
                            "First {} on the mount: {:.4} °/s for {:.2} s, {:.3}° of travel. Watch the mount with a hand on the power switch. Type yes to send it, Enter to cancel.",
                            describe(&request),
                            request.rate_deg_s,
                            request.duration_ms as f64 / 1000.0,
                            request.rate_deg_s * request.duration_ms as f64 / 1000.0,
                        )));
                        self.pending = Some(request);
                    } else {
                        self.request(request, now, &mut out);
                    }
                }
                Err(e) => out.push(info(e)),
            },
        }
        out
    }

    /// A message copied from the receiver.
    pub fn tapped(&mut self, tapped: &Tapped, now: Nanos) -> Vec<Out> {
        let mut out = Vec::new();
        match &tapped.message {
            Message::Hello(hello) => {
                if self.session.as_deref() != Some(hello.session_id.as_str()) {
                    out.push(info(format!(
                        "phone session {} connected",
                        &hello.session_id[..8]
                    )));
                    self.log.write(
                        now,
                        "phone_session",
                        json!({ "session_id": hello.session_id }),
                    );
                }
                self.session = Some(hello.session_id.clone());
                self.clock.phone_boot(&hello.device.boot_id);
            }
            Message::ClockResult(result) => {
                if self.session.as_deref() == Some(result.session_id.as_str()) {
                    self.clock.add(result);
                }
            }
            Message::SampleBatch(batch) => {
                if self.session.as_deref() != Some(batch.session_id.as_str()) {
                    return out;
                }
                let Some(model) = self.clock.model().cloned() else {
                    return out;
                };
                for sample in &batch.samples {
                    if let Sample::DeviceMotion(m) = sample
                        && let Some(o) =
                            self.mapper
                                .observe(model.to_mac_ns(m.t_ns), m.rotation_rate, m.gravity)
                    {
                        out.extend(self.observation(o, now));
                    }
                }
            }
            _ => {}
        }
        out
    }

    /// One IMU observation in mount-axis terms (from the phone, or simulated).
    pub fn observation(&mut self, observation: Observation, now: Nanos) -> Vec<Out> {
        self.last_observation = Some(observation);
        let actions = self.controller.observe(observation, now);
        let mut out = Vec::new();
        self.carry_out(actions, now, &mut out);
        out.extend(self.changes(now));
        out
    }

    /// Call every few milliseconds.
    pub fn tick(&mut self, now: Nanos) -> Vec<Out> {
        let mut out = Vec::new();
        for report in self.adapter.poll(now) {
            self.log.write(
                now,
                "mount_report",
                json!({ "report": format!("{report:?}") }),
            );
            let actions = match report {
                MountReport::Acknowledged(id) => self.controller.acknowledged(id, now),
                MountReport::TransportLost => self.controller.transport_lost(now),
            };
            self.carry_out(actions, now, &mut out);
        }
        for p in self.adapter.take_positions() {
            self.log.write(
                now,
                "mount_position",
                json!({ "t_ns": p.t_ns, "deg": p.deg }),
            );
            self.last_position = Some(p);
        }
        for note in self.adapter.take_notes() {
            self.log.write(now, "mount_note", json!({ "note": note }));
            out.push(alert(note));
        }
        let actions = self.controller.tick(now);
        self.carry_out(actions, now, &mut out);
        out.extend(self.changes(now));
        out
    }

    /// Stops everything; the caller keeps ticking briefly, then exits.
    pub fn quit(&mut self, now: Nanos) -> Vec<Out> {
        let mut out = Vec::new();
        let actions = self.controller.shutdown(now);
        self.carry_out(actions, now, &mut out);
        self.stage = Stage::Done;
        self.log.write(now, "quit", json!({}));
        out.push(info("Stopped. Exiting."));
        out
    }

    fn request(&mut self, request: MoveRequest, now: Nanos, out: &mut Vec<Out>) {
        self.log
            .write(now, "request", json!({ "request": request }));
        match self.controller.request_move(request.clone(), now) {
            Ok(actions) => {
                out.push(info(format!(
                    "moving: {} at {:.4} °/s for {:.2} s (Enter stops)",
                    describe(&request),
                    request.rate_deg_s,
                    request.duration_ms as f64 / 1000.0
                )));
                self.carry_out(actions, now, out);
            }
            Err(refused) => {
                self.log
                    .write(now, "refused", json!({ "reason": refused.0 }));
                out.push(alert(refused.to_string()));
            }
        }
        out.extend(self.changes(now));
    }

    fn result(
        &mut self,
        result: Result<Vec<Action>, cwb_mount_core::Refused>,
        now: Nanos,
        out: &mut Vec<Out>,
    ) {
        match result {
            Ok(actions) => self.carry_out(actions, now, out),
            Err(refused) => {
                self.log
                    .write(now, "refused", json!({ "reason": refused.0 }));
                out.push(alert(refused.to_string()));
            }
        }
        out.extend(self.changes(now));
    }

    /// Carries out actions in order; a failed send is a lost link.
    fn carry_out(&mut self, actions: Vec<Action>, now: Nanos, out: &mut Vec<Out>) {
        let mut queue: std::collections::VecDeque<Action> = actions.into();
        while let Some(action) = queue.pop_front() {
            match action {
                Action::Send(command) => {
                    self.log.write(now, "send", json!({ "command": command }));
                    if let Err(e) = self.adapter.send(&command, now) {
                        self.log.write(now, "send_failed", json!({ "error": e.0 }));
                        queue.extend(self.controller.transport_lost(now));
                    }
                }
                Action::Alert(text) => {
                    self.log.write(now, "alert", json!({ "text": text }));
                    out.push(alert(text));
                }
            }
        }
    }

    /// State changes, new faults and finished commands since last time.
    fn changes(&mut self, now: Nanos) -> Vec<Out> {
        let mut out = Vec::new();
        let state = self.controller.state();
        if state != self.last_state {
            self.log.write(
                now,
                "state",
                json!({ "from": format!("{:?}", self.last_state), "to": format!("{state:?}") }),
            );
            self.last_state = state;
            out.push(info(format!("state: {state:?}")));
        }
        let faults = self.controller.faults();
        for fault in &faults[self.faults_seen..] {
            self.log.write(now, "fault", json!({ "fault": fault }));
            let next = if fault.kind == FaultKind::ProcessShutdown {
                ""
            } else {
                " Type reset once the mount is still."
            };
            out.push(alert(format!(
                "FAULT {:?}: {}.{next}",
                fault.kind, fault.detail
            )));
        }
        self.faults_seen = faults.len();
        let records = self.controller.records();
        let done = records[self.records_seen..]
            .iter()
            .take_while(|r| r.last_stage().is_final())
            .count();
        for record in &records[self.records_seen..self.records_seen + done] {
            self.log.write(now, "record", json!({ "record": record }));
            if record.command_id.is_some() {
                out.push(info(format!(
                    "{}: {:?}{}{}",
                    describe(&record.request),
                    record.last_stage(),
                    record
                        .commanded_deg
                        .map(|c| format!(", commanded {c:+.3}°"))
                        .unwrap_or_default(),
                    record
                        .observed_deg
                        .map(|o| format!(", IMU {o:+.3}°"))
                        .unwrap_or_default(),
                )));
            }
        }
        self.records_seen += done;
        out
    }

    fn status(&self, now: Nanos) -> String {
        let imu = match self.last_observation {
            Some(o) => format!(
                "IMU {:.0} ms old: azimuth {:+.3} °/s, altitude {:+.3} °/s, tube at {:.1}°",
                (now - o.t_ns) as f64 / MS as f64,
                o.rate_deg_s[0],
                o.rate_deg_s[1],
                o.altitude_deg
            ),
            None if self.session.is_none() => "IMU: no phone session yet".into(),
            None if self.clock.model().is_none() => "IMU: waiting for a clock model".into(),
            None => "IMU: no samples yet".into(),
        };
        let clock = self.clock.model().map_or(String::new(), |m| {
            format!(", clock ±{:.1} ms", m.uncertainty_ns as f64 / 1e6)
        });
        let [az, alt] = self.controller.unconfirmed_travel_deg();
        let mount = self
            .last_position
            .map_or("mount positions: none read".into(), |p| {
                format!(
                    "mount positions: azimuth {:.4}°, altitude {:.4}°",
                    p.deg[0], p.deg[1]
                )
            });
        format!(
            "state {:?}; {imu}{clock}; unconfirmed travel azimuth {az:+.3}°, altitude {alt:+.3}°; {mount}",
            self.controller.state()
        )
    }

    fn parse_move(&mut self, word: &str, args: &[&str]) -> Result<MoveRequest, String> {
        let (axis, direction) = match word {
            "az+" => (Axis::Azimuth, Direction::Positive),
            "az-" => (Axis::Azimuth, Direction::Negative),
            "alt+" => (Axis::Altitude, Direction::Positive),
            "alt-" => (Axis::Altitude, Direction::Negative),
            other => return Err(format!("unknown command {other:?}; type help")),
        };
        let number = |i: usize, default: f64, what: &str| -> Result<f64, String> {
            args.get(i).map_or(Ok(default), |a| {
                a.parse::<f64>()
                    .ok()
                    .filter(|v| v.is_finite() && *v > 0.0)
                    .ok_or_else(|| format!("{what} {a:?} isn't a positive number"))
            })
        };
        let rate = number(0, self.config.moves.rate_deg_s, "rate")?;
        let seconds = number(1, self.config.moves.seconds, "seconds")?;
        let id = self.next_request;
        self.next_request += 1;
        Ok(MoveRequest {
            request_id: format!("operator-{id}"),
            axis,
            direction,
            // The rate the hand controller will actually run, so commanded
            // travel matches what is sent.
            rate_deg_s: quantized_deg_s(rate),
            duration_ms: (seconds * 1000.0).round() as u64,
        })
    }
}

fn describe(request: &MoveRequest) -> String {
    format!(
        "{} {}",
        match request.axis {
            Axis::Azimuth => "azimuth",
            Axis::Altitude => "altitude",
        },
        match request.direction {
            Direction::Positive => "positive",
            Direction::Negative => "negative",
        }
    )
}
