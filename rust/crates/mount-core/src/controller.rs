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

use std::collections::{HashSet, VecDeque};

use serde::Serialize;
use thiserror::Error;

use crate::{
    FaultKind, MountEvent, MountState, SafetyConfig,
    command::{
        Axis, CommandId, CommandRecord, Direction, MountCommand, MoveRequest, Nanos, Observation,
        Stage,
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
    transmitted: Nanos,
    acked: Option<Nanos>,
    lease_end: Nanos,
    stop_sent: Option<Nanos>,
    /// Stopped by the operator rather than at the end of its lease.
    cancelled: bool,
    /// The axis tally's observed travel when the command was transmitted.
    observed_at_start: f64,
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
        match self.state {
            MountState::Armed | MountState::Moving | MountState::Stopping => {
                self.fault(FaultKind::UnexpectedMotion, now, detail)
            }
            _ => Vec::new(),
        }
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
        let mut record = CommandRecord {
            command_id: None,
            request: request.clone(),
            stages: vec![(Stage::Requested, now)],
            reason: None,
            fault: None,
            commanded_deg: None,
            observed_deg: None,
        };
        let c = &self.config;
        let refusal = if !self.request_ids.insert(request.request_id.clone()) {
            Some("duplicate request ID; not re-sent".to_string())
        } else if self.state != MountState::Armed {
            Some(format!("not armed (state {:?})", self.state))
        } else if self.active.is_some() {
            Some("another command is active".into())
        } else if !(request.rate_deg_s.is_finite()
            && request.rate_deg_s >= c.min_rate_deg_s
            && request.rate_deg_s <= c.max_rate_deg_s)
        {
            Some(format!(
                "rate {} °/s is outside {}–{} °/s",
                request.rate_deg_s, c.min_rate_deg_s, c.max_rate_deg_s
            ))
        } else if request.duration_ms == 0 || request.duration_ms > c.max_duration_ms {
            Some(format!(
                "duration {} ms is outside 1–{} ms",
                request.duration_ms, c.max_duration_ms
            ))
        } else if !self.fresh(now) {
            Some("IMU data is stale".into())
        } else if !self.in_envelope() {
            Some("altitude is outside the envelope".into())
        } else if !self.still(self.config.still_deg_s) {
            Some("the mount is not still".into())
        } else {
            None
        };
        if let Some(reason) = refusal {
            record.stages.push((Stage::Rejected, now));
            record.reason = Some(reason.clone());
            self.records.push(record);
            return Err(Refused(reason));
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
            transmitted: now,
            acked: None,
            lease_end: now + request.duration_ms as Nanos * MS,
            stop_sent: None,
            cancelled: false,
            observed_at_start: self.tally[request.axis.index()].observed_deg,
        });
        self.still_since = None;
        self.go(MountEvent::MotionCommandSent);
        Ok(vec![Action::Send(MountCommand::Move {
            id,
            axis: request.axis,
            direction: request.direction,
            rate_deg_s: request.rate_deg_s,
        })])
    }

    /// The mount acknowledged a command. Late or unknown acknowledgements are ignored.
    pub fn acknowledged(&mut self, id: CommandId, now: Nanos) -> Vec<Action> {
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
        if a.acked.is_none() && now - a.transmitted > c.ack_deadline_ms as Nanos * MS {
            return self.fault(
                FaultKind::AcknowledgementMissing,
                now,
                "the mount did not acknowledge the command",
            );
        }
        let rate = self.smoothed(a.axis).unwrap_or(0.0);
        let signed = rate * a.direction.sign();
        if signed < -c.motion_deg_s {
            return self.fault(
                FaultKind::OppositeMotion,
                now,
                &format!(
                    "{:?} moving {rate:+.3} °/s, opposite to the command",
                    a.axis
                ),
            );
        }
        if rate.abs() > a.rate_deg_s * (1.0 + c.overspeed_fraction) + c.motion_deg_s {
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
            MountState::Moving => {
                if now >= a.lease_end {
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

    fn while_latched(&mut self, now: Nanos) -> Vec<Action> {
        let fresh = self.fresh(now);
        let rate_still = fresh && self.still(self.config.still_deg_s);
        if rate_still {
            if self.still_since.is_none() {
                // Coasting after the stop is over: measure creep from here.
                self.still_since = Some(now);
                self.tally = [Tally::default(); 2];
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
        let commanded =
            a.rate_deg_s * a.direction.sign() * (stop_sent - a.transmitted) as f64 / 1e9;
        let observed = self.tally[a.axis.index()].observed_deg - a.observed_at_start;
        let record = &mut self.records[a.record];
        record.commanded_deg = Some(commanded);
        record.observed_deg = Some(observed);
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
            .filter(|a| a.axis == axis)
            .map_or(0.0, |a| {
                let end = a.stop_sent.unwrap_or(now);
                a.rate_deg_s * a.direction.sign() * (end - a.transmitted) as f64 / 1e9
            });
        self.tally[axis.index()].commanded_deg + active
    }

    /// An axis that has turned further than commanded by more than the
    /// tolerance, with its observed and commanded travel.
    fn beyond_commanded(&self, now: Nanos) -> Option<(Axis, f64, f64)> {
        Axis::BOTH.into_iter().find_map(|axis| {
            let observed = self.tally[axis.index()].observed_deg;
            let commanded = self.commanded_travel(axis, now);
            (observed.abs() > commanded.abs() + self.config.travel_tolerance_deg)
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
