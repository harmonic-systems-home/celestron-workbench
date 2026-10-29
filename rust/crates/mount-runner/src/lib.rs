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

use std::collections::{HashSet, VecDeque};

use cwb_mount_celestron::{CelestronAdapter, Position, Transaction, encode::quantized_deg_s};
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
/// The raw gyroscope's offset is measured over this much stillness when the
/// operator arms (ADR 0013).
pub const BIAS_WINDOW_MS: Nanos = 3_000;
/// At 100 Hz, about 2.5 s of the window.
const BIAS_MIN_SAMPLES: usize = 250;
/// The mount's own positions must stay within this during the window. A
/// still mount reads exactly the same (one unit is 0.077″, 0.00002°); a
/// creep of 0.2″/s seen on 2026-10-29 moves 0.00018° in 3 s.
const BIAS_STILL_DEG: f64 = 0.0001;
/// While armed and idle, the mount's own positions moving this far from
/// where they settled is unexplained motion.
const IDLE_CREEP_DEG: f64 = 0.0003;
/// Arming and moving need a position read this recently: proof the hand
/// controller link is alive (positions are read every 250 ms while idle).
const POSITION_MAX_AGE_MS: Nanos = 1_000;
/// While armed and idle, a link silent this long is lost.
const POSITION_LOST_MS: Nanos = 1_500;

/// What the runner needs from a mount adapter beyond [`MountAdapter`].
pub trait RunnerAdapter: MountAdapter {
    /// The mount's own axis positions read since the last call.
    fn take_positions(&mut self) -> Vec<Position> {
        Vec::new()
    }
    fn take_notes(&mut self) -> Vec<String> {
        Vec::new()
    }
    /// Motion commands' serial exchanges since the last call.
    fn take_transactions(&mut self) -> Vec<Transaction> {
        Vec::new()
    }
    /// Whether the adapter reads the mount's positions while idle: if so,
    /// their freshness shows the link is alive.
    fn reports_positions(&self) -> bool {
        false
    }
}

impl RunnerAdapter for CelestronAdapter {
    fn take_positions(&mut self) -> Vec<Position> {
        CelestronAdapter::take_positions(self)
    }
    fn take_notes(&mut self) -> Vec<String> {
        CelestronAdapter::take_notes(self)
    }
    fn take_transactions(&mut self) -> Vec<Transaction> {
        CelestronAdapter::take_transactions(self)
    }
    fn reports_positions(&self) -> bool {
        true
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
    /// Recent mount positions, for the stillness check while measuring bias.
    positions: VecDeque<Position>,
    /// Gravity from the newest device-motion sample, phone body frame.
    gravity: Option<[f64; 3]>,
    /// Recent raw gyroscope samples on the Mac clock, rad/s.
    gyro: VecDeque<(Nanos, [f64; 3])>,
    /// The raw gyroscope's offset, measured at arming. While set, the safety
    /// checks use the raw gyroscope; before it, iOS's fused rate.
    bias: Option<[f64; 3]>,
    /// The last time a command was moving or stopping: the adapter reads no
    /// positions then, so silence doesn't count against the link.
    last_busy: Nanos,
    /// Where the mount settled since it was last busy or armed; idle
    /// positions are compared with it.
    settled: Option<Position>,
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
            positions: VecDeque::new(),
            gravity: None,
            gyro: VecDeque::new(),
            bias: None,
            last_busy: now,
            settled: None,
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
                    "Checklist confirmed. Type status until it shows IMU fresh, keep the mount still 3 s, then arm. Type help for commands.",
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
                if let Err(why) = self.link_alive(now) {
                    out.push(alert(format!("refused: {why}")));
                    return out;
                }
                if self.session.is_some() {
                    match self.measure_bias(now) {
                        Ok(text) => out.push(info(text)),
                        Err(why) => {
                            out.push(alert(format!("refused: {why}")));
                            return out;
                        }
                    }
                }
                let result = self.controller.arm(now);
                if result.is_err() {
                    self.bias = None;
                }
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
                    match sample {
                        Sample::DeviceMotion(m) => {
                            self.gravity = Some(m.gravity);
                            // iOS's fused rate absorbs slow steady rotation
                            // as bias, so it serves only until arming.
                            if self.bias.is_none()
                                && let Some(o) = self.mapper.observe(
                                    model.to_mac_ns(m.t_ns),
                                    m.rotation_rate,
                                    m.gravity,
                                )
                            {
                                out.extend(self.observation(o, now));
                            }
                        }
                        Sample::Gyro(g) => {
                            let t = model.to_mac_ns(g.t_ns);
                            self.gyro.push_back((t, g.rotation_rate));
                            while self
                                .gyro
                                .front()
                                .is_some_and(|(s, _)| *s < t - BIAS_WINDOW_MS * MS)
                            {
                                self.gyro.pop_front();
                            }
                            if let (Some(b), Some(gravity)) = (self.bias, self.gravity) {
                                let rate = [
                                    g.rotation_rate[0] - b[0],
                                    g.rotation_rate[1] - b[1],
                                    g.rotation_rate[2] - b[2],
                                ];
                                if let Some(o) = self.mapper.observe(t, rate, gravity) {
                                    out.extend(self.observation(o, now));
                                }
                            }
                        }
                        _ => {}
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
            self.positions.push_back(p);
            while self
                .positions
                .front()
                .is_some_and(|q| q.t_ns < p.t_ns - BIAS_WINDOW_MS * MS)
            {
                self.positions.pop_front();
            }
        }
        for t in self.adapter.take_transactions() {
            let bytes: Vec<String> = t.bytes.iter().map(|b| format!("{b:02X}")).collect();
            self.log.write(
                now,
                "serial",
                json!({
                    "sent_ns": t.sent_ns,
                    "reply_ns": t.reply_ns,
                    "bytes": bytes.join(" "),
                    "outcome": t.outcome,
                }),
            );
        }
        for note in self.adapter.take_notes() {
            self.log.write(now, "mount_note", json!({ "note": note }));
            out.push(alert(note));
        }
        match self.controller.state() {
            MountState::Moving | MountState::Stopping => {
                self.last_busy = now;
                self.settled = None;
            }
            MountState::Armed if self.adapter.reports_positions() => {
                out.extend(self.check_creep(now));
                let heard = self
                    .last_position
                    .map_or(self.last_busy, |p| p.t_ns.max(self.last_busy));
                if now - heard > POSITION_LOST_MS * MS {
                    self.log
                        .write(now, "link_silent", json!({ "since_ns": heard }));
                    out.push(alert(
                        "the hand controller stopped answering position reads",
                    ));
                    let actions = self.controller.transport_lost(now);
                    self.carry_out(actions, now, &mut out);
                }
            }
            // Not armed: the next arming settles afresh.
            _ => self.settled = None,
        }
        let actions = self.controller.tick(now);
        self.carry_out(actions, now, &mut out);
        out.extend(self.changes(now));
        out
    }

    /// While armed and idle, the mount's own positions must stay where they
    /// settled: this catches a creep far too slow for the gyroscope.
    fn check_creep(&mut self, now: Nanos) -> Vec<Out> {
        let mut out = Vec::new();
        let Some(p) = self.last_position.filter(|p| p.t_ns > self.last_busy) else {
            return out;
        };
        let settled = *self.settled.get_or_insert(p);
        let moved = [0, 1].map(|i| wrap_deg(p.deg[i] - settled.deg[i]));
        if moved.iter().any(|m| m.abs() > IDLE_CREEP_DEG) {
            let detail = format!(
                "the mount's own positions moved azimuth {:+.4}°, altitude {:+.4}° while idle: a creep the gyroscope can't see. Power-cycle the mount if it continues",
                moved[0], moved[1]
            );
            self.log
                .write(now, "mount_creep", json!({ "moved_deg": moved }));
            let actions = self.controller.mount_moved(now, &detail);
            self.carry_out(actions, now, &mut out);
        }
        out
    }

    /// With an adapter that reads positions, a recent read proves the link.
    fn link_alive(&self, now: Nanos) -> Result<(), String> {
        if !self.adapter.reports_positions() {
            return Ok(());
        }
        match self.last_position {
            Some(p) if now - p.t_ns <= POSITION_MAX_AGE_MS * MS => Ok(()),
            Some(p) => Err(format!(
                "the mount's position was last read {:.1} s ago: the hand controller link may be down (restart the runner)",
                (now - p.t_ns) as f64 / 1e9
            )),
            None => Err("the mount's position hasn't been read yet: wait a moment".into()),
        }
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
        if let Err(why) = self.link_alive(now) {
            self.log.write(now, "refused", json!({ "reason": why }));
            out.push(alert(format!("refused: {why}")));
            return;
        }
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
            // Back to read-only (disarmed or reset): measure afresh next time.
            if state == MountState::ConnectedReadOnly && self.bias.take().is_some() {
                self.log.write(now, "gyro_bias_cleared", json!({}));
            }
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

    /// Measures the raw gyroscope's offset over the last [`BIAS_WINDOW_MS`],
    /// which must be still: the mount's own positions must not change. A
    /// steady slow rotation looks just like an offset to a gyroscope, so this
    /// independent check matters.
    fn measure_bias(&mut self, now: Nanos) -> Result<String, String> {
        let since = now - BIAS_WINDOW_MS * MS;
        let samples: Vec<[f64; 3]> = self
            .gyro
            .iter()
            .filter(|(t, _)| *t >= since)
            .map(|(_, r)| *r)
            .collect();
        if samples.len() < BIAS_MIN_SAMPLES {
            return Err(format!(
                "need {:.0} s of raw gyroscope data to measure its offset ({} samples so far): turn on Raw gyroscope in the app, keep the mount still, and try again",
                BIAS_WINDOW_MS as f64 / 1000.0,
                samples.len()
            ));
        }
        let recent: Vec<&Position> = self.positions.iter().filter(|p| p.t_ns >= since).collect();
        for axis in 0..2 {
            // Relative to the first reading, so a wrap through 0° is harmless.
            let (lo, hi) = recent.iter().fold((f64::MAX, f64::MIN), |(lo, hi), p| {
                let d = wrap_deg(p.deg[axis] - recent[0].deg[axis]);
                (lo.min(d), hi.max(d))
            });
            if recent.len() >= 2 && hi - lo > BIAS_STILL_DEG {
                return Err(format!(
                    "the mount's own position changed {:.4}° in the last {:.0} s: it must be still while the gyroscope offset is measured",
                    hi - lo,
                    BIAS_WINDOW_MS as f64 / 1000.0
                ));
            }
        }
        let n = samples.len() as f64;
        let bias = [0, 1, 2].map(|i| samples.iter().map(|s| s[i]).sum::<f64>() / n);
        self.bias = Some(bias);
        let deg = bias.map(f64::to_degrees);
        self.log.write(
            now,
            "gyro_bias",
            json!({ "rad_s": bias, "deg_s": deg, "samples": samples.len(), "positions": recent.len() }),
        );
        Ok(format!(
            "raw gyroscope offset {:+.4}, {:+.4}, {:+.4} °/s from {} samples; safety checks now use the raw gyroscope",
            deg[0],
            deg[1],
            deg[2],
            samples.len()
        ))
    }

    fn status(&self, now: Nanos) -> String {
        let imu = match self.last_observation {
            Some(o) => format!(
                "IMU {} ({:.0} ms old): azimuth {:+.3} °/s, altitude {:+.3} °/s, tube at {:.1}°",
                if now - o.t_ns <= self.config.safety.imu_max_age_ms as Nanos * MS {
                    "fresh"
                } else {
                    "STALE"
                },
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
                    "mount positions ({:.0} ms old): azimuth {:.4}°, altitude {:.4}°",
                    (now - p.t_ns) as f64 / 1e6,
                    p.deg[0],
                    p.deg[1]
                )
            });
        let source = if self.bias.is_some() {
            ", raw gyroscope"
        } else if self.session.is_some() {
            ", iOS fused rate until armed"
        } else {
            ""
        };
        format!(
            "state {:?}; {imu}{clock}{source}; unconfirmed travel azimuth {az:+.3}°, altitude {alt:+.3}°; {mount}",
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

/// An angle difference in (-180, 180].
fn wrap_deg(d: f64) -> f64 {
    let d = d.rem_euclid(360.0);
    if d > 180.0 { d - 360.0 } else { d }
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
