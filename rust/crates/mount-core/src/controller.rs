//! The interlock controller (ADR 0005, plan Prompt 6).
//!
//! Pure and deterministic: every input carries the current Mac time, and
//! every method returns the [`Action`]s the caller must carry out at once,
//! in order. The caller (simulator harness or hardware runner) owns all I/O.
//!
//! Inputs: operator actions, mount acknowledgements, IMU observations in
//! mount-axis terms, transport loss, and periodic [`Controller::tick`]s.
//! Any interlock failure sends `StopAll` and latches a fault; only an
//! operator reset, once the IMU shows the mount still, clears it, and
//! re-arming after that is a separate operator action.
//!
//! A single move need not be visible to the IMU: small or slow steps are
//! allowed. Instead the controller keeps a running tally per axis of net
//! commanded travel and the travel the IMU integrated during each command.
//! Once the commanded travel reaches `verify_travel_deg`, the observed
//! travel must have kept up, or the session latches a stall (or opposite
//! motion, if it went the other way). Wrong-axis, wrong-way, too-fast and
//! not-stopping motion are still caught from the rates during each move.
//! Observed travel is integrated continuously while armed or latched, so
//! motion too slow for the rate checks (a slow move whose stop was ignored)
//! is caught once it exceeds the commanded travel by `travel_tolerance_deg`.
//! The phone's gyroscope offset wanders by a few thousandths of a degree a
//! second, so that integral drifts too, and an altitude axis that isn't quite
//! horizontal leaks altitude motion into the azimuth rate. An axis whose own
//! positions haven't changed ([`Controller::mount_still`]), even across a
//! command on the other axis, has what the IMU integrated for it meanwhile
//! discarded.
//!
//! A goto (ADR 0014) has no lease: it ends when the axis's goto-finished
//! flag is set and two position readings in a row agree on the target, and
//! the controller then sends the same stop as for a move. The IMU checks still
//! apply, with the goto rate cap for overspeed and a reversal allowed near
//! the target; the axis positions add an overshoot check, a deadline per
//! leg and a check that the axis settled on its target.

use std::collections::{HashSet, VecDeque};

use serde::Serialize;
use thiserror::Error;

use crate::{
    FaultKind, MountEvent, MountState, SafetyConfig,
    command::{
        Axis, CommandId, CommandRecord, Direction, GotoOutcome, GotoRequest, GotoSpeed,
        MountCommand, MoveRequest, Nanos, Observation, Request, Stage, deg_to_units, units_between,
        units_to_deg, wrap_units,
    },
    transition,
};

const MS: Nanos = 1_000_000;

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Action {
    /// Transmit this to the mount now.
    Send(MountCommand),
    /// Show this to the operator now.
    Alert(String),
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct FaultRecord {
    pub kind: FaultKind,
    pub t_ns: Nanos,
    pub detail: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Error)]
#[error("refused: {0}")]
pub struct Refused(pub String);

#[derive(Debug, Clone)]
struct Active {
    record: usize,
    id: CommandId,
    axis: Axis,
    direction: Direction,
    rate_deg_s: f64,
    /// When the command was handed to the adapter; the send deadline runs
    /// from here.
    requested: Nanos,
    /// When it left for the mount, once the adapter says so.
    sent: Option<Nanos>,
    /// The lease and commanded travel run from here: the hand-over until the
    /// adapter reports the send.
    transmitted: Nanos,
    acked: Option<Nanos>,
    duration: Nanos,
    lease_end: Nanos,
    stop_sent: Option<Nanos>,
    /// Stopped by the operator rather than at the end of its lease.
    cancelled: bool,
    /// The axis tally's observed travel when the command was transmitted.
    observed_at_start: f64,
    /// Set for a goto; `direction` is then its current leg's.
    goto: Option<GotoRun>,
    /// A move reversing the axis's last direction, or the first on it:
    /// anti-backlash may take up the slack fast at its start.
    reversal: bool,
}

/// A goto in progress. Positions are axis units.
#[derive(Debug, Clone)]
struct GotoRun {
    speed: GotoSpeed,
    start: u32,
    target: u32,
    legs: Vec<u32>,
    /// Index of the leg being run.
    leg: usize,
    /// Where the current leg was planned to start from.
    leg_start: u32,
    /// Newest position and goto-finished flag read since the current leg left.
    position: Option<(Nanos, u32)>,
    done: Option<bool>,
    /// When the position last changed (by more than a unit), and to what.
    steady: Option<(Nanos, u32)>,
    overshoot: i64,
    crossings: u32,
    /// Which side of the target the last differing reading was on.
    side: i64,
    /// When the last leg settled.
    settled: Option<Nanos>,
    at_stop: Option<u32>,
}

impl GotoRun {
    fn leg_target(&self) -> u32 {
        self.legs[self.leg]
    }

    fn last_leg(&self) -> bool {
        self.leg + 1 == self.legs.len()
    }

    fn leg_sign(&self) -> i64 {
        units_between(self.leg_start, self.leg_target()).signum()
    }

    /// The planned leg target furthest from the start, signed, in degrees.
    fn reach_deg(&self) -> f64 {
        self.legs
            .iter()
            .map(|l| units_between(self.start, *l))
            .max_by_key(|d| d.abs())
            .map_or(0.0, units_to_deg)
    }

    fn outcome(&self, settled_from: Option<Nanos>) -> GotoOutcome {
        let last = self.position.map(|p| p.1);
        GotoOutcome {
            start: self.start,
            target: self.target,
            legs: self.legs.clone(),
            at_stop: self.at_stop,
            last,
            error_units: last.map(|l| units_between(self.target, l)),
            overshoot_units: self.overshoot,
            crossings: self.crossings,
            settle_ms: self
                .settled
                .zip(settled_from)
                .map(|(s, from)| (s - from) as f64 / MS as f64),
        }
    }
}

/// Net signed travel on one axis since the IMU last confirmed it: commanded
/// by completed commands, and integrated from IMU rates continuously.
#[derive(Debug, Clone, Copy, Default)]
struct Tally {
    commanded_deg: f64,
    observed_deg: f64,
}

pub struct Controller {
    config: SafetyConfig,
    state: MountState,
    transport_up: bool,
    window: VecDeque<Observation>,
    active: Option<Active>,
    records: Vec<CommandRecord>,
    request_ids: HashSet<String>,
    faults: Vec<FaultRecord>,
    next_id: CommandId,
    last_stop: Option<Nanos>,
    still_since: Option<Nanos>,
    /// After a fault: the IMU has confirmed both axes still.
    confirmed_still: bool,
    /// Indexed by [`Axis::index`].
    tally: [Tally; 2],
    /// Time of the last observation integrated into the tallies.
    integrated_to: Option<Nanos>,
    /// Per axis: observed travel when the mount's own positions last showed
    /// that axis unchanged. Cleared by a command on the axis, a reset of its
    /// tally, and positions that moved.
    still_mark: [Option<f64>; 2],
    /// Per axis: the direction it was last commanded to move.
    last_direction: [Option<Direction>; 2],
}

impl Controller {
    /// Refuses a configuration with problems ([`SafetyConfig::problems`]).
    pub fn new(config: SafetyConfig) -> Result<Self, Vec<String>> {
        let problems = config.problems();
        if !problems.is_empty() {
            return Err(problems);
        }
        Ok(Self {
            config,
            state: MountState::Disconnected,
            transport_up: false,
            window: VecDeque::new(),
            active: None,
            records: Vec::new(),
            request_ids: HashSet::new(),
            faults: Vec::new(),
            next_id: 1,
            last_stop: None,
            still_since: None,
            confirmed_still: false,
            tally: [Tally::default(); 2],
            integrated_to: None,
            still_mark: [None; 2],
            last_direction: [None; 2],
        })
    }

    pub fn state(&self) -> MountState {
        self.state
    }

    pub fn config(&self) -> &SafetyConfig {
        &self.config
    }

    pub fn records(&self) -> &[CommandRecord] {
        &self.records
    }

    pub fn faults(&self) -> &[FaultRecord] {
        &self.faults
    }

    /// Net commanded travel per axis not yet confirmed by the IMU.
    pub fn unconfirmed_travel_deg(&self) -> [f64; 2] {
        [self.tally[0].commanded_deg, self.tally[1].commanded_deg]
    }

    /// The ID of the command currently leased, if any.
    pub fn active_command(&self) -> Option<CommandId> {
        self.active.as_ref().map(|a| a.id)
    }

    // --- Operator and transport -------------------------------------------

    pub fn connect(&mut self, _now: Nanos) -> Result<Vec<Action>, Refused> {
        self.require(MountState::Disconnected, "connect")?;
        self.transport_up = true;
        self.go(MountEvent::TransportConnected);
        Ok(Vec::new())
    }

    pub fn disconnect(&mut self, _now: Nanos) -> Result<Vec<Action>, Refused> {
        self.require(MountState::ConnectedReadOnly, "disconnect")?;
        self.transport_up = false;
        self.go(MountEvent::TransportClosed);
        Ok(Vec::new())
    }

    /// The adapter lost its link to the mount.
    pub fn transport_lost(&mut self, now: Nanos) -> Vec<Action> {
        self.transport_up = false;
        match self.state {
            // Already latched: re-sent stops failing must not stack faults.
            MountState::Disconnected | MountState::FaultLatched => Vec::new(),
            MountState::ConnectedReadOnly => {
                self.go(MountEvent::TransportClosed);
                Vec::new()
            }
            _ => self.fault(
                FaultKind::TransportLost,
                now,
                "mount link lost; motion may continue: be ready to cut mount power",
            ),
        }
    }

    /// The link is back (the adapter reconnected). Nothing else changes: a
    /// latched session still needs an operator reset, which now returns to
    /// read-only, and arming is separate as always. A disconnected session
    /// connects.
    pub fn transport_restored(&mut self, _now: Nanos) -> Vec<Action> {
        self.transport_up = true;
        if self.state == MountState::Disconnected {
            self.go(MountEvent::TransportConnected);
        }
        Vec::new()
    }

    /// Explicit operator action; nothing else arms the session.
    pub fn arm(&mut self, now: Nanos) -> Result<Vec<Action>, Refused> {
        self.require(MountState::ConnectedReadOnly, "arm")?;
        if !self.fresh(now) {
            return Err(Refused("IMU data is stale".into()));
        }
        if !self.still(self.config.still_deg_s) {
            return Err(Refused("the mount is not still".into()));
        }
        if !self.in_envelope() {
            return Err(Refused("altitude is outside the envelope".into()));
        }
        self.tally = [Tally::default(); 2];
        self.still_mark = [None; 2];
        self.go(MountEvent::OperatorArm);
        Ok(Vec::new())
    }

    pub fn disarm(&mut self, _now: Nanos) -> Result<Vec<Action>, Refused> {
        self.require(MountState::Armed, "disarm")?;
        self.go(MountEvent::OperatorDisarm);
        Ok(Vec::new())
    }

    /// Clears a latched fault once the IMU shows the mount still. The
    /// session returns to read-only; arming again is a separate action.
    pub fn reset(&mut self, now: Nanos) -> Result<Vec<Action>, Refused> {
        self.require(MountState::FaultLatched, "reset")?;
        if !self.fresh(now) {
            return Err(Refused(
                "IMU data is stale, so the mount can't be confirmed still".into(),
            ));
        }
        if !self.still(self.config.still_deg_s) {
            return Err(Refused("the mount is still moving".into()));
        }
        self.tally = [Tally::default(); 2];
        self.still_mark = [None; 2];
        self.go(MountEvent::OperatorReset);
        if !self.transport_up {
            self.go(MountEvent::TransportClosed);
        }
        Ok(Vec::new())
    }

    /// Operator stop: ends the current command early. Harmless at any time.
    pub fn stop(&mut self, now: Nanos) -> Vec<Action> {
        match self.state {
            MountState::Moving => self.begin_stop(now, true),
            MountState::Disconnected => Vec::new(),
            _ => {
                self.last_stop = Some(now);
                vec![Action::Send(MountCommand::StopAll)]
            }
        }
    }

    /// The mount's own position readings show motion that no command
    /// explains (a creep too slow for the IMU). Latches unexpected motion
    /// unless the session is disarmed or already latched.
    pub fn mount_moved(&mut self, now: Nanos, detail: &str) -> Vec<Action> {
        self.still_mark = [None; 2];
        match self.state {
            MountState::Armed | MountState::Moving | MountState::Stopping => {
                self.fault(FaultKind::UnexpectedMotion, now, detail)
            }
            _ => Vec::new(),
        }
    }

    /// A position read with no command active (armed and idle, or latched):
    /// `unchanged` per axis, since the previous such read, even if the other
    /// axis moved in between. For an unchanged axis, observed travel since
    /// its previous call is gyroscope drift or leakage from the other axis
    /// and is discarded, so it can't build up into a false unexpected-motion
    /// fault. The rate checks still apply. Tube motion the motor encoders
    /// can't see (a slipping clutch) slower than `motion_deg_s` then goes
    /// unnoticed.
    pub fn mount_still(&mut self, now: Nanos, unchanged: [bool; 2]) -> Vec<Action> {
        let idle = match self.state {
            MountState::Armed => self.active.is_none(),
            MountState::FaultLatched => self.still_since.is_some(),
            _ => false,
        };
        for axis in Axis::BOTH {
            let i = axis.index();
            if !idle || !unchanged[i] {
                self.still_mark[i] = None;
                continue;
            }
            match self.still_mark[i] {
                Some(mark) => self.tally[i].observed_deg = mark,
                None => self.still_mark[i] = Some(self.tally[i].observed_deg),
            }
        }
        if idle { self.evaluate(now) } else { Vec::new() }
    }

    pub fn emergency_stop(&mut self, now: Nanos) -> Vec<Action> {
        self.fault(FaultKind::EmergencyStop, now, "emergency stop")
    }

    /// The process is shutting down: stop everything first.
    pub fn shutdown(&mut self, now: Nanos) -> Vec<Action> {
        if self.state == MountState::Disconnected {
            return Vec::new();
        }
        self.fault(FaultKind::ProcessShutdown, now, "process shutting down")
    }

    // --- Commands -----------------------------------------------------------

    /// Checks every interlock; on success returns the motion command to send.
    /// Every request is recorded, refused or not.
    pub fn request_move(
        &mut self,
        request: MoveRequest,
        now: Nanos,
    ) -> Result<Vec<Action>, Refused> {
        let mut record = new_record(Request::Move(request.clone()), now);
        let c = self.config.clone();
        let refusal = if let Some(why) = self.refuse_any(&request.request_id) {
            Some(why)
        } else if !(request.rate_deg_s.is_finite()
            && request.rate_deg_s >= c.min_rate_deg_s
            && request.rate_deg_s <= c.max_rate_deg_s)
        {
            Some(format!(
                "rate {} °/s is outside {}–{} °/s",
                request.rate_deg_s, c.min_rate_deg_s, c.max_rate_deg_s
            ))
        } else if request.fixed_rate.is_some_and(|r| !(1..=9).contains(&r)) {
            Some("a fixed rate must be 1–9".into())
        } else if request.duration_ms == 0 || request.duration_ms > c.max_duration_ms {
            Some(format!(
                "duration {} ms is outside 1–{} ms",
                request.duration_ms, c.max_duration_ms
            ))
        } else {
            self.refuse_now(now)
        };
        if let Some(reason) = refusal {
            return Err(self.reject(record, reason, now));
        }

        let id = self.next_id;
        self.next_id += 1;
        record.command_id = Some(id);
        record.stages.push((Stage::Transmitted, now));
        self.records.push(record);
        self.active = Some(Active {
            record: self.records.len() - 1,
            id,
            axis: request.axis,
            direction: request.direction,
            rate_deg_s: request.rate_deg_s,
            requested: now,
            sent: None,
            transmitted: now,
            acked: None,
            duration: request.duration_ms as Nanos * MS,
            lease_end: now + request.duration_ms as Nanos * MS,
            stop_sent: None,
            cancelled: false,
            observed_at_start: self.tally[request.axis.index()].observed_deg,
            goto: None,
            // Unknown before the first command: the gears may have been
            // left either way.
            reversal: self.last_direction[request.axis.index()] != Some(request.direction),
        });
        self.last_direction[request.axis.index()] = Some(request.direction);
        self.still_since = None;
        self.still_mark[request.axis.index()] = None;
        self.go(MountEvent::MotionCommandSent);
        Ok(vec![Action::Send(MountCommand::Move {
            id,
            axis: request.axis,
            direction: request.direction,
            rate_deg_s: request.rate_deg_s,
            fixed_rate: request.fixed_rate,
        })])
    }

    /// Checks every interlock for a goto from `start`, the axis's own
    /// position (axis units) read since it last moved; on success returns
    /// the first leg's command. Every request is recorded, refused or not.
    pub fn request_goto(
        &mut self,
        request: GotoRequest,
        start: u32,
        now: Nanos,
    ) -> Result<Vec<Action>, Refused> {
        let mut record = new_record(Request::Goto(request.clone()), now);
        let c = self.config.clone();
        let delta = deg_to_units(request.delta_deg);
        let margin = deg_to_units(c.approach_margin_deg);
        let target = wrap_units(i64::from(start) + delta);
        // With the approach flag, a goto heading the wrong way first goes
        // the margin past the target.
        let legs: Vec<u32> = match request.approach {
            Some(way) if delta.signum() != way.sign() as i64 => vec![
                wrap_units(i64::from(target) - way.sign() as i64 * margin),
                target,
            ],
            _ => vec![target],
        };
        let mut from = start;
        let mut longest = 0;
        let mut offsets = Vec::new();
        for leg in &legs {
            longest = longest.max(units_between(from, *leg).abs());
            offsets.push(units_to_deg(units_between(start, *leg)));
            from = *leg;
        }
        let altitude = self.window.back().map(|o| o.altitude_deg);
        let refusal = if let Some(why) = self.refuse_any(&request.request_id) {
            Some(why)
        } else if !request.delta_deg.is_finite() || delta == 0 {
            Some(format!(
                "goto of {}° is less than one position unit",
                request.delta_deg
            ))
        } else if longest > deg_to_units(c.max_goto_deg) {
            Some(format!(
                "a goto leg of {:.4}° exceeds max_goto_deg {}°",
                units_to_deg(longest),
                c.max_goto_deg
            ))
        } else if request.speed == GotoSpeed::Fast && !c.allow_fast_goto {
            Some("fast gotos are off until their speed is measured (allow_fast_goto)".into())
        } else if request.axis == Axis::Altitude
            && let Some(alt) = altitude
            && offsets
                .iter()
                .any(|d| alt + d < c.min_altitude_deg || alt + d > c.max_altitude_deg)
        {
            Some("the goto would take the altitude outside the envelope".into())
        } else {
            self.refuse_now(now)
        };
        if let Some(reason) = refusal {
            return Err(self.reject(record, reason, now));
        }

        let id = self.next_id;
        self.next_id += 1;
        record.command_id = Some(id);
        record.stages.push((Stage::Transmitted, now));
        self.records.push(record);
        let run = GotoRun {
            speed: request.speed,
            start,
            target,
            legs,
            leg: 0,
            leg_start: start,
            position: None,
            done: None,
            steady: None,
            overshoot: 0,
            crossings: 0,
            side: 0,
            settled: None,
            at_stop: None,
        };
        let command = MountCommand::Goto {
            id,
            axis: request.axis,
            target: run.leg_target(),
            speed: run.speed,
        };
        self.active = Some(Active {
            record: self.records.len() - 1,
            id,
            axis: request.axis,
            direction: direction_of(run.leg_sign()),
            rate_deg_s: c.max_goto_rate_deg_s,
            requested: now,
            sent: None,
            transmitted: now,
            acked: None,
            duration: 0,
            lease_end: Nanos::MAX,
            stop_sent: None,
            cancelled: false,
            observed_at_start: self.tally[request.axis.index()].observed_deg,
            goto: Some(run),
            reversal: false,
        });
        self.last_direction[request.axis.index()] = Some(direction_of(delta));
        self.still_since = None;
        self.still_mark[request.axis.index()] = None;
        self.go(MountEvent::MotionCommandSent);
        Ok(vec![Action::Send(command)])
    }

    /// The axis's own position, read at `t_ns` while a goto runs or stops.
    /// Readings from before the current leg left are ignored.
    pub fn position(&mut self, axis: Axis, t_ns: Nanos, units: u32, now: Nanos) -> Vec<Action> {
        if let Some(a) = &mut self.active
            && a.axis == axis
            && let Some(sent) = a.sent
            && t_ns >= sent
            && let Some(g) = &mut a.goto
        {
            g.position = Some((t_ns, units));
            if !g
                .steady
                .is_some_and(|(_, u)| units_between(u, units).abs() <= 1)
            {
                g.steady = Some((t_ns, units));
            }
            if g.last_leg() {
                let off = units_between(g.target, units);
                g.overshoot = g.overshoot.max(off * g.leg_sign());
                let side = off.signum();
                if side != 0 {
                    if g.side != 0 && side != g.side {
                        g.crossings += 1;
                    }
                    g.side = side;
                }
            }
        }
        self.evaluate(now)
    }

    /// The axis's goto-finished flag, read at `t_ns`.
    pub fn slew_done(&mut self, axis: Axis, t_ns: Nanos, done: bool, now: Nanos) -> Vec<Action> {
        if let Some(a) = &mut self.active
            && a.axis == axis
            && let Some(sent) = a.sent
            && t_ns >= sent
            && let Some(g) = &mut a.goto
        {
            g.done = Some(done);
        }
        self.evaluate(now)
    }

    /// A command left for the mount at `sent_ns`. The lease restarts from
    /// then, so a command delayed on its way (by at most the send deadline)
    /// still gets its full duration, and the acknowledgement deadline starts.
    pub fn sent(&mut self, id: CommandId, sent_ns: Nanos, now: Nanos) -> Vec<Action> {
        if let Some(a) = &mut self.active
            && a.id == id
            && a.sent.is_none()
        {
            let at = sent_ns.clamp(a.requested, now);
            a.sent = Some(at);
            if a.goto.is_none() {
                a.transmitted = at;
                a.lease_end = at + a.duration;
            }
            // The latest leg's transmission.
            if let Some(stage) = self.records[a.record]
                .stages
                .iter_mut()
                .rev()
                .find(|s| s.0 == Stage::Transmitted)
            {
                stage.1 = at;
            }
        }
        Vec::new()
    }

    /// The mount acknowledged a command. One with no send report counts as
    /// sent when it was handed over. Late or unknown acknowledgements are
    /// ignored.
    pub fn acknowledged(&mut self, id: CommandId, now: Nanos) -> Vec<Action> {
        if let Some(a) = &self.active
            && a.id == id
            && a.sent.is_none()
        {
            let requested = a.requested;
            self.sent(id, requested, now);
        }
        if let Some(a) = &mut self.active
            && a.id == id
            && a.acked.is_none()
        {
            a.acked = Some(now);
            self.records[a.record]
                .stages
                .push((Stage::Acknowledged, now));
        }
        Vec::new()
    }

    // --- Observation and time -----------------------------------------------

    pub fn observe(&mut self, observation: Observation, now: Nanos) -> Vec<Action> {
        // Observations can arrive late or out of order; keep them sorted.
        let at = self.window.partition_point(|o| o.t_ns <= observation.t_ns);
        self.window.insert(at, observation);
        let newest = self.window.back().map_or(observation.t_ns, |o| o.t_ns);
        let horizon = newest - self.config.smoothing_ms as Nanos * MS;
        while self.window.front().is_some_and(|o| o.t_ns < horizon) {
            self.window.pop_front();
        }
        // Integrate observed travel. Out-of-order samples are skipped.
        if self.integrated_to.is_none_or(|t| observation.t_ns > t) {
            let tracking = matches!(
                self.state,
                MountState::Armed
                    | MountState::Moving
                    | MountState::Stopping
                    | MountState::FaultLatched
            );
            if let Some(t) = self.integrated_to
                && tracking
            {
                let dt = (observation.t_ns - t).min(self.config.imu_max_age_ms as Nanos * MS);
                for axis in Axis::BOTH {
                    self.tally[axis.index()].observed_deg +=
                        observation.rate_deg_s[axis.index()] * dt as f64 / 1e9;
                }
            }
            self.integrated_to = Some(observation.t_ns);
        }
        self.evaluate(now)
    }

    /// Call at least every few tens of milliseconds: deadlines are checked here.
    pub fn tick(&mut self, now: Nanos) -> Vec<Action> {
        self.evaluate(now)
    }

    fn evaluate(&mut self, now: Nanos) -> Vec<Action> {
        match self.state {
            MountState::Disconnected | MountState::ConnectedReadOnly => Vec::new(),
            MountState::Armed => {
                if !self.fresh(now) {
                    self.fault(FaultKind::StaleImu, now, "IMU data stale while armed")
                } else if !self.still(self.config.motion_deg_s) {
                    self.fault(
                        FaultKind::UnexpectedMotion,
                        now,
                        "motion while no command is active",
                    )
                } else {
                    self.check_overshoot(now)
                }
            }
            MountState::Moving | MountState::Stopping => self.check_motion(now),
            MountState::FaultLatched => self.while_latched(now),
        }
    }

    fn check_motion(&mut self, now: Nanos) -> Vec<Action> {
        let c = self.config.clone();
        let Some(a) = self.active.clone() else {
            return self.fault(
                FaultKind::InvalidTransition,
                now,
                "moving with no active command",
            );
        };
        if !self.fresh(now) {
            return self.fault(FaultKind::StaleImu, now, "IMU data stale during motion");
        }
        match a.sent {
            // A stop sent first overtakes the move, which then never leaves.
            None if a.stop_sent.is_none()
                && now - a.requested > c.send_deadline_ms as Nanos * MS =>
            {
                return self.fault(
                    FaultKind::CommandTimeout,
                    now,
                    &format!(
                        "the command wasn't sent to the mount within {} ms",
                        c.send_deadline_ms
                    ),
                );
            }
            Some(sent) if a.acked.is_none() && now - sent > c.ack_deadline_ms as Nanos * MS => {
                return self.fault(
                    FaultKind::AcknowledgementMissing,
                    now,
                    "the mount did not acknowledge the command",
                );
            }
            _ => {}
        }
        let rate = self.smoothed(a.axis).unwrap_or(0.0);
        let signed = rate * a.direction.sign();
        // A servo may reverse briefly as it settles near a goto's target.
        let near_target = a.goto.as_ref().is_some_and(|g| {
            g.position.is_some_and(|(_, p)| {
                units_to_deg(units_between(g.leg_target(), p).abs()) <= c.approach_margin_deg
            })
        });
        if signed < -c.motion_deg_s && !near_target {
            return self.fault(
                FaultKind::OppositeMotion,
                now,
                &format!(
                    "{:?} moving {rate:+.3} °/s, opposite to the command",
                    a.axis
                ),
            );
        }
        // Anti-backlash takes up the slack fast at the start of a reversal.
        let takeup = a.reversal && a.sent.is_some_and(|s| now - s <= c.takeup_ms as Nanos * MS);
        let allowance = if takeup {
            c.takeup_overspeed_deg_s
        } else {
            0.0
        };
        if rate.abs() > a.rate_deg_s * (1.0 + c.overspeed_fraction) + c.motion_deg_s + allowance {
            return self.fault(
                FaultKind::Overspeed,
                now,
                &format!(
                    "{:?} moving {rate:+.3} °/s, commanded {} °/s",
                    a.axis, a.rate_deg_s
                ),
            );
        }
        let other = self.smoothed(a.axis.other()).unwrap_or(0.0);
        if other.abs() > c.motion_deg_s {
            return self.fault(
                FaultKind::UnexpectedMotion,
                now,
                &format!("{:?} moving {other:+.3} °/s, not commanded", a.axis.other()),
            );
        }
        if !self.in_envelope() {
            return self.fault(FaultKind::LimitBreach, now, "altitude left the envelope");
        }
        let overshoot = self.check_overshoot(now);
        if !overshoot.is_empty() {
            return overshoot;
        }

        match self.state {
            MountState::Moving if a.goto.is_some() => self.check_goto(now),
            MountState::Moving => {
                // The lease runs only once the move has left; until then
                // the send deadline applies.
                if a.sent.is_some() && now >= a.lease_end {
                    return self.begin_stop(now, false);
                }
                Vec::new()
            }
            _ => {
                let stop_sent = a.stop_sent.unwrap_or(now);
                if self.still(c.still_deg_s) {
                    let since = *self.still_since.get_or_insert(now);
                    if now - since >= c.still_hold_ms as Nanos * MS {
                        return self.complete(now);
                    }
                } else {
                    self.still_since = None;
                    if now - stop_sent > c.stop_deadline_ms as Nanos * MS {
                        return self.fault(
                            FaultKind::StopNotObserved,
                            now,
                            "motion continued after stop: cut mount power",
                        );
                    }
                }
                Vec::new()
            }
        }
    }

    /// A goto's own checks, from the axis's positions: its deadline, an
    /// overshoot or a wrong-way run beyond the margin, and whether the leg
    /// has finished. A finished leg sends the next, or ends the goto with a
    /// stop.
    fn check_goto(&mut self, now: Nanos) -> Vec<Action> {
        let c = self.config.clone();
        let still = self.still(c.still_deg_s);
        let Some(a) = self.active.as_mut() else {
            return Vec::new();
        };
        let (Some(sent), Some(g)) = (a.sent, a.goto.as_mut()) else {
            return Vec::new();
        };
        let margin = deg_to_units(c.approach_margin_deg);
        let distance = units_to_deg(units_between(g.leg_start, g.leg_target()).abs());
        let allowed =
            (distance / c.min_goto_rate_deg_s * 1e9) as Nanos + c.goto_settle_ms as Nanos * MS;
        if now - sent > allowed {
            let detail = format!(
                "the goto didn't finish within {:.1} s",
                allowed as f64 / 1e9
            );
            return self.fault(FaultKind::CommandTimeout, now, &detail);
        }
        let Some((t, p)) = g.position else {
            return Vec::new();
        };
        let past = units_between(g.leg_target(), p) * g.leg_sign();
        if past > margin {
            let detail = format!(
                "{:?} went {:.4}° past its goto target",
                a.axis,
                units_to_deg(past)
            );
            return self.fault(FaultKind::Overshoot, now, &detail);
        }
        if units_between(g.leg_start, p) * g.leg_sign() < -margin {
            let detail = format!(
                "{:?} is {:.4}° the wrong way from where its goto started",
                a.axis,
                units_to_deg(units_between(g.leg_start, p).abs())
            );
            return self.fault(FaultKind::OppositeMotion, now, &detail);
        }
        // Two readings in a row the same; the IMU then confirms the axis
        // still before the goto completes, as for any stop.
        let held = g.steady.is_some_and(|(since, _)| since < t);
        if g.done != Some(true) || !held {
            return Vec::new();
        }
        let error = units_between(g.leg_target(), p);
        if units_to_deg(error.abs()) > c.goto_tolerance_deg {
            let detail = format!(
                "{:?} settled {:+.4}° from its goto target",
                a.axis,
                units_to_deg(error)
            );
            return self.fault(FaultKind::MissedTarget, now, &detail);
        }
        if g.last_leg() {
            g.settled = Some(t);
            return self.begin_stop(now, false);
        }
        // The approach leg: back to the target slowly, once the IMU too
        // shows the axis still, as for any request.
        if !still {
            return Vec::new();
        }
        g.leg_start = g.leg_target();
        g.leg += 1;
        g.position = None;
        g.done = None;
        g.steady = None;
        let command = MountCommand::Goto {
            id: a.id,
            axis: a.axis,
            target: g.leg_target(),
            speed: GotoSpeed::Slow,
        };
        a.direction = direction_of(g.leg_sign());
        a.requested = now;
        a.sent = None;
        a.acked = None;
        self.records[a.record]
            .stages
            .push((Stage::Transmitted, now));
        vec![Action::Send(command)]
    }

    fn while_latched(&mut self, now: Nanos) -> Vec<Action> {
        let fresh = self.fresh(now);
        let rate_still = fresh && self.still(self.config.still_deg_s);
        if rate_still {
            if self.still_since.is_none() {
                // Coasting after the stop is over: measure creep from here.
                self.still_since = Some(now);
                self.tally = [Tally::default(); 2];
                self.still_mark = [None; 2];
            }
        } else {
            self.still_since = None;
        }
        let creeping = self.beyond_commanded(now).is_some();
        if creeping {
            self.confirmed_still = false;
        }
        if self.confirmed_still {
            return Vec::new();
        }
        if rate_still && !creeping {
            let since = self.still_since.unwrap_or(now);
            if now - since >= self.config.still_hold_ms as Nanos * MS {
                self.confirmed_still = true;
            }
            return Vec::new();
        }
        let due = self
            .last_stop
            .is_none_or(|t| now - t >= self.config.stop_resend_ms as Nanos * MS);
        if !due {
            return Vec::new();
        }
        self.last_stop = Some(now);
        // Until the IMU confirms the mount is still, the operator is told:
        // a silent IMU is no evidence that motion has ended.
        let alert = if fresh {
            "motion continues after stop: cut mount power"
        } else {
            "IMU silent, so the stop can't be confirmed: check the mount and cut mount power if it is moving"
        };
        vec![
            Action::Send(MountCommand::StopAll),
            Action::Alert(alert.into()),
        ]
    }

    // --- Internals ------------------------------------------------------------

    fn begin_stop(&mut self, now: Nanos, cancelled: bool) -> Vec<Action> {
        let Some(a) = &mut self.active else {
            return Vec::new();
        };
        a.stop_sent = Some(now);
        a.cancelled = cancelled;
        if let Some(g) = &mut a.goto {
            g.at_stop = g.position.map(|p| p.1);
        }
        let axis = a.axis;
        self.records[a.record].stages.push((Stage::StopSent, now));
        self.last_stop = Some(now);
        self.still_since = None;
        self.go(MountEvent::StopRequested);
        vec![Action::Send(MountCommand::Stop { axis })]
    }

    fn complete(&mut self, now: Nanos) -> Vec<Action> {
        let Some(a) = self.active.take() else {
            return Vec::new();
        };
        let stop_sent = a.stop_sent.unwrap_or(now);
        let commanded = match &a.goto {
            // A goto that settled was commanded to its target; one stopped
            // early, as far as its positions showed.
            Some(g) if g.settled.is_some() => units_to_deg(units_between(g.start, g.target)),
            Some(g) => g
                .position
                .map_or(0.0, |(_, p)| units_to_deg(units_between(g.start, p))),
            // A move overtaken by its stop never left: nothing was commanded.
            None if a.sent.is_some() => {
                a.rate_deg_s * a.direction.sign() * (stop_sent - a.transmitted).max(0) as f64 / 1e9
            }
            None => 0.0,
        };
        let observed = self.tally[a.axis.index()].observed_deg - a.observed_at_start;
        let record = &mut self.records[a.record];
        record.commanded_deg = Some(commanded);
        record.observed_deg = Some(observed);
        record.goto = a.goto.as_ref().map(|g| g.outcome(a.sent));
        record.stages.push((
            if a.cancelled {
                Stage::Cancelled
            } else {
                Stage::Completed
            },
            now,
        ));
        self.go(MountEvent::MotionEndedObserved);
        self.check_travel(a.axis, commanded, now)
    }

    /// Commanded travel on `axis` since the tally began, including the
    /// active command so far.
    fn commanded_travel(&self, axis: Axis, now: Nanos) -> f64 {
        let active = self
            .active
            .as_ref()
            .filter(|a| a.axis == axis && a.sent.is_some())
            .map_or(0.0, |a| match &a.goto {
                // Anywhere up to the furthest leg target.
                Some(g) => g.reach_deg(),
                None => {
                    let end = a.stop_sent.unwrap_or(now);
                    a.rate_deg_s * a.direction.sign() * (end - a.transmitted) as f64 / 1e9
                }
            });
        self.tally[axis.index()].commanded_deg + active
    }

    /// An axis that has turned further than commanded by more than the
    /// tolerance, with its observed and commanded travel.
    /// While a command runs, the axis may be anywhere between where it
    /// started and where it is headed: a goto back toward the start
    /// (a reversal) mustn't count as commanded travel already undone.
    fn beyond_commanded(&self, now: Nanos) -> Option<(Axis, f64, f64)> {
        Axis::BOTH.into_iter().find_map(|axis| {
            let observed = self.tally[axis.index()].observed_deg;
            let commanded = self.commanded_travel(axis, now);
            let started = self.tally[axis.index()].commanded_deg;
            let allowed = commanded.abs().max(started.abs());
            (observed.abs() > allowed + self.config.travel_tolerance_deg)
                .then_some((axis, observed, commanded))
        })
    }

    fn check_overshoot(&mut self, now: Nanos) -> Vec<Action> {
        match self.beyond_commanded(now) {
            Some((axis, observed, commanded)) => self.fault(
                FaultKind::UnexpectedMotion,
                now,
                &format!(
                    "{axis:?} turned {observed:+.3}° against {commanded:+.3}° commanded: \
                     if it is still moving, cut mount power"
                ),
            ),
            None => Vec::new(),
        }
    }

    /// Adds a completed command to its axis tally; once enough travel has
    /// been commanded, the IMU must confirm it.
    fn check_travel(&mut self, axis: Axis, commanded: f64, now: Nanos) -> Vec<Action> {
        let c = &self.config;
        let tally = &mut self.tally[axis.index()];
        tally.commanded_deg += commanded;
        let Tally {
            commanded_deg: want,
            observed_deg: got,
        } = *tally;
        if want.abs() < c.verify_travel_deg {
            return Vec::new();
        }
        let along = got * want.signum();
        let needed = c.min_observed_fraction * want.abs();
        if along >= needed {
            *tally = Tally::default();
            self.still_mark[axis.index()] = None;
            return Vec::new();
        }
        let detail = format!(
            "{axis:?}: {want:+.3}° commanded since the last confirmation, {got:+.3}° observed"
        );
        let kind = if along <= -needed {
            FaultKind::OppositeMotion
        } else {
            FaultKind::Stall
        };
        self.fault(kind, now, &detail)
    }

    fn fault(&mut self, kind: FaultKind, now: Nanos, detail: &str) -> Vec<Action> {
        self.faults.push(FaultRecord {
            kind,
            t_ns: now,
            detail: detail.to_owned(),
        });
        if let Some(a) = self.active.take() {
            let stage = match kind {
                FaultKind::AcknowledgementMissing | FaultKind::CommandTimeout => Stage::TimedOut,
                FaultKind::StaleImu | FaultKind::TransportLost | FaultKind::ProcessShutdown => {
                    Stage::Unknown
                }
                _ => Stage::Cancelled,
            };
            let record = &mut self.records[a.record];
            record.goto = a.goto.as_ref().map(|g| GotoOutcome {
                at_stop: g.at_stop.or(g.position.map(|p| p.1)),
                ..g.outcome(a.sent)
            });
            if a.stop_sent.is_none() {
                record.stages.push((Stage::StopSent, now));
            }
            record.stages.push((stage, now));
            record.fault = Some(kind);
            record.reason = Some(detail.to_owned());
        }
        let was = self.state;
        self.go(MountEvent::Fault(kind));
        self.last_stop = Some(now);
        self.still_since = None;
        self.confirmed_still = false;
        // Unconfirmed travel is meaningless after a fault: start afresh.
        self.tally = [Tally::default(); 2];
        self.still_mark = [None; 2];
        let mut actions = Vec::new();
        if was != MountState::Disconnected {
            actions.push(Action::Send(MountCommand::StopAll));
        }
        actions.push(Action::Alert(format!(
            "{kind:?}: {detail}. Stopped and latched; operator reset required."
        )));
        actions
    }

    fn go(&mut self, event: MountEvent) {
        self.state = match transition(self.state, event) {
            Ok(next) => next,
            // Never expected: treat as a fault rather than ignore it.
            Err(_) => MountState::FaultLatched,
        };
    }

    /// Refusals common to every request: a repeated ID, not armed, or a
    /// command already active.
    fn refuse_any(&mut self, request_id: &str) -> Option<String> {
        if !self.request_ids.insert(request_id.to_owned()) {
            Some("duplicate request ID; not re-sent".into())
        } else if self.state != MountState::Armed {
            Some(format!("not armed (state {:?})", self.state))
        } else if self.active.is_some() {
            Some("another command is active".into())
        } else {
            None
        }
    }

    /// Refusals from the IMU now: stale, outside the envelope, or moving.
    fn refuse_now(&self, now: Nanos) -> Option<String> {
        if !self.fresh(now) {
            Some("IMU data is stale".into())
        } else if !self.in_envelope() {
            Some("altitude is outside the envelope".into())
        } else if !self.still(self.config.still_deg_s) {
            Some("the mount is not still".into())
        } else {
            None
        }
    }

    fn reject(&mut self, mut record: CommandRecord, reason: String, now: Nanos) -> Refused {
        record.stages.push((Stage::Rejected, now));
        record.reason = Some(reason.clone());
        self.records.push(record);
        Refused(reason)
    }

    fn require(&self, state: MountState, action: &str) -> Result<(), Refused> {
        if self.state == state {
            Ok(())
        } else {
            Err(Refused(format!("can't {action} in state {:?}", self.state)))
        }
    }

    /// The newest observation is at most `imu_max_age_ms` old, and no more
    /// than that ahead of `now`: one stamped seconds ahead by a wrong clock
    /// model would otherwise stay "fresh" after the phone went silent.
    fn fresh(&self, now: Nanos) -> bool {
        let max = self.config.imu_max_age_ms as Nanos * MS;
        self.window
            .back()
            .is_some_and(|o| (now - o.t_ns).abs() <= max)
    }

    fn smoothed(&self, axis: Axis) -> Option<f64> {
        if self.window.is_empty() {
            return None;
        }
        let sum: f64 = self.window.iter().map(|o| o.rate_deg_s[axis.index()]).sum();
        Some(sum / self.window.len() as f64)
    }

    fn still(&self, limit: f64) -> bool {
        Axis::BOTH
            .iter()
            .all(|a| self.smoothed(*a).is_some_and(|r| r.abs() < limit))
    }

    fn in_envelope(&self) -> bool {
        self.window.back().is_some_and(|o| {
            o.altitude_deg >= self.config.min_altitude_deg
                && o.altitude_deg <= self.config.max_altitude_deg
        })
    }
}

fn new_record(request: Request, now: Nanos) -> CommandRecord {
    CommandRecord {
        command_id: None,
        request,
        stages: vec![(Stage::Requested, now)],
        reason: None,
        fault: None,
        commanded_deg: None,
        observed_deg: None,
        goto: None,
    }
}

fn direction_of(sign: i64) -> Direction {
    if sign < 0 {
        Direction::Negative
    } else {
        Direction::Positive
    }
}
