//! Runs a scripted scenario: operator actions at fixed times, a simulated
//! mount, and an IMU whose observations arrive after a latency, all wired to
//! the interlock [`Controller`] the way the hardware runner will be. Time is
//! stepped in fixed increments, so every run is deterministic.

use std::collections::VecDeque;

use cwb_mount_core::{
    Action, Controller, FaultRecord, GotoRequest, MountAdapter, MountCommand, MountReport,
    MountState, MoveRequest, Nanos, Observation, SafetyConfig,
};

use crate::{SimFaults, SimMount};

const MS: Nanos = 1_000_000;
/// Simulation step and controller tick.
pub const STEP_MS: u64 = 5;
/// IMU sample interval (100 Hz, as the phone delivers).
pub const IMU_INTERVAL_MS: u64 = 10;

#[derive(Debug, Clone, PartialEq)]
pub enum Op {
    Connect,
    Arm,
    Disarm,
    Move(MoveRequest),
    /// From the axis's position as the mount reports it now.
    Goto(GotoRequest),
    Stop,
    EmergencyStop,
    Shutdown,
    Reset,
}

#[derive(Debug, Clone)]
pub struct Scenario {
    pub config: SafetyConfig,
    pub faults: SimFaults,
    /// Operator actions, by time in ms.
    pub script: Vec<(u64, Op)>,
    pub run_ms: u64,
    /// Delay before an IMU observation reaches the controller.
    pub imu_latency_ms: u64,
    pub start_altitude_deg: f64,
    pub seed: u64,
}

impl Default for Scenario {
    fn default() -> Self {
        Self {
            config: SafetyConfig::default(),
            faults: SimFaults::default(),
            script: Vec::new(),
            run_ms: 6_000,
            imu_latency_ms: 60,
            start_altitude_deg: 30.0,
            seed: 1,
        }
    }
}

/// Everything that happened, for assertions.
#[derive(Debug, Clone, Default)]
pub struct Trace {
    pub final_state: Option<MountState>,
    pub states: Vec<(Nanos, MountState)>,
    pub faults: Vec<FaultRecord>,
    pub records: Vec<cwb_mount_core::CommandRecord>,
    /// Commands the controller asked to send, with the time.
    pub sent: Vec<(Nanos, MountCommand)>,
    pub alerts: Vec<(Nanos, String)>,
    /// Operator actions the controller refused.
    pub refusals: Vec<(Nanos, String)>,
    /// True mount angles and rates at every step.
    pub motion: Vec<(Nanos, [f64; 2], [f64; 2])>,
    /// For each fault: the actions returned with it, in order.
    pub fault_actions: Vec<(Nanos, Vec<Action>)>,
}

impl Trace {
    /// True angle change of each axis from `from_ns` to the end of the run.
    pub fn travel_after(&self, from_ns: Nanos) -> [f64; 2] {
        let start = self
            .motion
            .iter()
            .find(|m| m.0 >= from_ns)
            .map_or([0.0; 2], |m| m.1);
        let end = self.motion.last().map_or([0.0; 2], |m| m.1);
        [end[0] - start[0], end[1] - start[1]]
    }

    pub fn final_rates(&self) -> [f64; 2] {
        self.motion.last().map_or([0.0; 2], |m| m.2)
    }

    pub fn is_still_at_end(&self) -> bool {
        self.final_rates().iter().all(|r| r.abs() < 1e-9)
    }

    pub fn first_fault_ns(&self) -> Option<Nanos> {
        self.faults.first().map(|f| f.t_ns)
    }

    pub fn moves_sent(&self) -> usize {
        self.sent
            .iter()
            .filter(|(_, c)| matches!(c, MountCommand::Move { .. }))
            .count()
    }

    pub fn gotos_sent(&self) -> Vec<MountCommand> {
        self.sent
            .iter()
            .filter(|(_, c)| matches!(c, MountCommand::Goto { .. }))
            .map(|(_, c)| c.clone())
            .collect()
    }
}

pub fn run(scenario: &Scenario) -> Trace {
    let mut controller = Controller::new(scenario.config.clone()).expect("valid safety config");
    let mut mount = SimMount::new(
        scenario.faults.clone(),
        scenario.start_altitude_deg,
        scenario.seed,
    );
    let mut trace = Trace::default();
    let mut in_flight: VecDeque<(Nanos, Observation)> = VecDeque::new();
    let mut script: Vec<(u64, Op)> = scenario.script.clone();
    script.sort_by_key(|(t, _)| *t);
    let mut script = script.into_iter().peekable();
    let step = STEP_MS as Nanos * MS;
    let mut last_state = controller.state();
    trace.states.push((0, last_state));

    let mut now: Nanos = 0;
    while now <= scenario.run_ms as Nanos * MS {
        // Operator actions due now.
        while script.peek().is_some_and(|(t, _)| *t as Nanos * MS <= now) {
            let (_, op) = script.next().expect("peeked");
            let result = match op {
                Op::Connect => controller.connect(now),
                Op::Arm => controller.arm(now),
                Op::Disarm => controller.disarm(now),
                Op::Move(request) => controller.request_move(request, now),
                Op::Goto(request) => {
                    let start = mount.position_units(request.axis);
                    controller.request_goto(request, start, now)
                }
                Op::Stop => Ok(controller.stop(now)),
                Op::EmergencyStop => Ok(controller.emergency_stop(now)),
                Op::Shutdown => Ok(controller.shutdown(now)),
                Op::Reset => controller.reset(now),
            };
            match result {
                Ok(actions) => carry_out(actions, now, &mut controller, &mut mount, &mut trace),
                Err(refused) => trace.refusals.push((now, refused.0)),
            }
        }

        // Mount reports.
        for report in mount.poll(now) {
            let actions = match report {
                MountReport::Sent { id, sent_ns } => controller.sent(id, sent_ns, now),
                MountReport::Acknowledged(id) => controller.acknowledged(id, now),
                MountReport::Position { axis, t_ns, units } => {
                    controller.position(axis, t_ns, units, now)
                }
                MountReport::SlewDone { axis, t_ns, done } => {
                    controller.slew_done(axis, t_ns, done, now)
                }
                MountReport::TransportLost => controller.transport_lost(now),
            };
            carry_out(actions, now, &mut controller, &mut mount, &mut trace);
        }

        // IMU: sample now, deliver after the latency.
        if now % (IMU_INTERVAL_MS as Nanos * MS) == 0
            && let Some(observation) = mount.observation(now)
        {
            in_flight.push_back((now + scenario.imu_latency_ms as Nanos * MS, observation));
        }
        while in_flight.front().is_some_and(|(t, _)| *t <= now) {
            let (_, observation) = in_flight.pop_front().expect("checked");
            let actions = controller.observe(observation, now);
            carry_out(actions, now, &mut controller, &mut mount, &mut trace);
        }

        let actions = controller.tick(now);
        carry_out(actions, now, &mut controller, &mut mount, &mut trace);

        if controller.state() != last_state {
            last_state = controller.state();
            trace.states.push((now, last_state));
        }
        mount.step(now + step, step);
        trace
            .motion
            .push((now + step, mount.angles_deg(), mount.rates_deg_s()));
        now += step;
    }
    trace.final_state = Some(controller.state());
    trace.faults = controller.faults().to_vec();
    trace.records = controller.records().to_vec();
    trace
}

/// Carries out actions in order, as the hardware runner will: a failed send
/// is reported to the controller as a lost link, which may add actions.
fn carry_out(
    actions: Vec<Action>,
    now: Nanos,
    controller: &mut Controller,
    mount: &mut SimMount,
    trace: &mut Trace,
) {
    let faults_before = controller.faults().len();
    let mut queue: VecDeque<Action> = actions.into();
    let mut taken = Vec::new();
    while let Some(action) = queue.pop_front() {
        taken.push(action.clone());
        match action {
            Action::Send(command) => {
                trace.sent.push((now, command.clone()));
                if mount.send(&command, now).is_err() {
                    queue.extend(controller.transport_lost(now));
                }
            }
            Action::Alert(text) => trace.alerts.push((now, text)),
        }
    }
    if controller.faults().len() > faults_before {
        trace.fault_actions.push((now, taken));
    }
}
