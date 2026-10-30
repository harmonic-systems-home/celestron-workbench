//! A deterministic two-axis mount and IMU simulator with fault injection
//! (plan Prompt 6, ADR 0005), and a harness that runs scripted scenarios
//! against the interlock [`Controller`]. Nothing here touches hardware.
//!
//! The simulated mount accelerates each axis toward its commanded rate,
//! acknowledges commands after a delay, and can misbehave on request:
//! delayed or missing acknowledgements, ignored stops, motion opposite to
//! the command, stalls, overspeed, a dropped link (with the axes still
//! turning, the worst case), a silent IMU, and an external bump.
//!
//! Gotos (ADR 0014) run each axis to a position: accelerating to the goto's
//! speed and decelerating into the target. They can overshoot and come
//! back, go the wrong way, stall, run fast, or carry on through a stop.
//! While a goto runs, and after a stop until the axis is done, the mount
//! reports the axis's position and goto-finished flag in turn, as the
//! serial adapter reads them.

pub mod harness;

use std::collections::VecDeque;

use cwb_mount_core::{
    Axis, CommandId, GotoSpeed, MountAdapter, MountCommand, MountReport, Nanos, Observation,
    TransportError, deg_to_units, units_between, units_to_deg, wrap_units,
};

const MS: Nanos = 1_000_000;
/// While a goto is watched, one read (position or goto-finished, in turn)
/// this often: about what the serial link manages.
pub const READ_EVERY_MS: u64 = 45;

/// Faults to inject. The default is a well-behaved mount.
#[derive(Debug, Clone, PartialEq)]
pub struct SimFaults {
    /// Time from command to acknowledgement.
    pub ack_delay_ms: u64,
    /// A move leaves for the motors this long after it was handed over, as
    /// when a serial adapter is mid-way through a position read; it is
    /// reported sent then. A stop before then cancels it.
    pub send_delay_ms: u64,
    pub drop_acks: bool,
    pub ignore_stop: bool,
    /// The axis turns opposite to the command.
    pub reverse: bool,
    /// The axis never moves.
    pub stall: bool,
    /// Actual rate = commanded rate × this.
    pub speed_factor: f64,
    /// The link drops at this time.
    pub disconnect_at_ms: Option<u64>,
    /// After the link drops, the axes keep their last rate (the worst case).
    pub keep_moving_when_disconnected: bool,
    /// The IMU stream stops at this time.
    pub imu_stops_at_ms: Option<u64>,
    /// An external push: the axis turns at this rate during this interval.
    pub bump: Option<(Axis, f64, u64, u64)>,
    /// Goto speeds, before `speed_factor`.
    pub goto_slow_deg_s: f64,
    pub goto_fast_deg_s: f64,
    /// A goto runs this far past its target, then comes back.
    pub goto_overshoot_deg: f64,
    /// A goto settles this far short of its target.
    pub goto_short_deg: f64,
    /// A stop doesn't end a goto, which carries on to its target.
    pub stop_ignores_goto: bool,
}

impl Default for SimFaults {
    fn default() -> Self {
        Self {
            ack_delay_ms: 20,
            send_delay_ms: 0,
            drop_acks: false,
            ignore_stop: false,
            reverse: false,
            stall: false,
            speed_factor: 1.0,
            disconnect_at_ms: None,
            keep_moving_when_disconnected: true,
            imu_stops_at_ms: None,
            bump: None,
            goto_slow_deg_s: 0.1,
            goto_fast_deg_s: 0.8,
            goto_overshoot_deg: 0.0,
            goto_short_deg: 0.0,
            stop_ignores_goto: false,
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
struct SimAxis {
    target_deg_s: f64,
    rate_deg_s: f64,
    angle_deg: f64,
    goto: Option<SimGoto>,
}

/// A goto in progress: heading for `aim`, which is first past `target`
/// when it overshoots.
#[derive(Debug, Clone, Copy, PartialEq)]
struct SimGoto {
    aim_deg: f64,
    target_deg: f64,
    speed_deg_s: f64,
}

/// Reading one axis's position and goto-finished flag in turn.
#[derive(Debug, Clone, Copy, PartialEq)]
struct Watch {
    axis: Axis,
    next: Nanos,
    position_next: bool,
    /// The flag has read done; the watch ends once a position read repeats
    /// the one before it.
    finished: bool,
    last: Option<u32>,
}

pub struct SimMount {
    faults: SimFaults,
    axes: [SimAxis; 2],
    connected: bool,
    link_lost_reported: bool,
    /// Acknowledgements due: when, and for which command.
    acks: VecDeque<(Nanos, CommandId)>,
    /// Moves on their way: when they leave (and are reported sent), command, axis.
    sends: VecDeque<(Nanos, CommandId, Axis)>,
    /// Delayed commands: when they reach the motors, and the command.
    arriving: Vec<(Nanos, MountCommand)>,
    watch: Option<Watch>,
    /// How fast an axis changes rate, °/s².
    accel_deg_s2: f64,
    start_altitude_deg: f64,
    noise: u64,
    /// Every command that reached the mount, with its arrival time.
    pub received: Vec<(Nanos, MountCommand)>,
}

impl SimMount {
    pub fn new(faults: SimFaults, start_altitude_deg: f64, seed: u64) -> Self {
        Self {
            faults,
            axes: [SimAxis::default(); 2],
            connected: true,
            link_lost_reported: false,
            acks: VecDeque::new(),
            sends: VecDeque::new(),
            arriving: Vec::new(),
            watch: None,
            accel_deg_s2: 5.0,
            start_altitude_deg,
            noise: seed.max(1),
            received: Vec::new(),
        }
    }

    /// Advances the physics by `dt_ns` ending at `now`.
    pub fn step(&mut self, now: Nanos, dt_ns: Nanos) {
        if !self.connected && !self.faults.keep_moving_when_disconnected {
            for axis in &mut self.axes {
                axis.target_deg_s = 0.0;
            }
        }
        let (due, later): (Vec<_>, Vec<_>) = std::mem::take(&mut self.arriving)
            .into_iter()
            .partition(|(at, _)| *at <= now);
        self.arriving = later;
        for (_, command) in due {
            self.arrive(&command, now);
        }
        let dt = dt_ns as f64 / 1e9;
        let max_change = self.accel_deg_s2 * dt;
        let accel = self.accel_deg_s2;
        for (i, axis) in self.axes.iter_mut().enumerate() {
            if let Some(g) = axis.goto {
                // Decelerate so as to stop at the aim.
                let error = g.aim_deg - axis.angle_deg;
                let speed = g.speed_deg_s.min((2.0 * accel * error.abs()).sqrt());
                axis.target_deg_s = speed.copysign(error);
            }
            let mut target = axis.target_deg_s;
            if let Some((bumped, rate, from, to)) = self.faults.bump
                && bumped.index() == i
                && (from as Nanos * MS..to as Nanos * MS).contains(&now)
            {
                target += rate;
            }
            let change = (target - axis.rate_deg_s).clamp(-max_change, max_change);
            axis.rate_deg_s += change;
            let step = axis.rate_deg_s * dt;
            match axis.goto {
                // Arriving within this step: stop on the aim.
                Some(g) if step.abs() >= (g.aim_deg - axis.angle_deg).abs() => {
                    axis.angle_deg = g.aim_deg;
                    axis.rate_deg_s = 0.0;
                    axis.target_deg_s = 0.0;
                    axis.goto = (g.aim_deg != g.target_deg).then_some(SimGoto {
                        aim_deg: g.target_deg,
                        ..g
                    });
                }
                _ => axis.angle_deg += step,
            }
        }
    }

    /// A command reaching the motors.
    fn arrive(&mut self, command: &MountCommand, now: Nanos) {
        let f = &self.faults;
        match *command {
            MountCommand::Move {
                axis,
                direction,
                rate_deg_s,
                ..
            } => {
                let a = &mut self.axes[axis.index()];
                a.goto = None;
                if !f.stall {
                    let sign = direction.sign() * if f.reverse { -1.0 } else { 1.0 };
                    a.target_deg_s = sign * rate_deg_s * f.speed_factor;
                }
            }
            MountCommand::Goto {
                axis,
                target,
                speed,
                ..
            } => {
                let a = &mut self.axes[axis.index()];
                let here = wrap_units(deg_to_units(a.angle_deg));
                let mut delta = units_to_deg(units_between(here, target));
                if f.reverse {
                    delta = -delta;
                }
                let target_deg = a.angle_deg + delta - f.goto_short_deg.copysign(delta);
                let speed = match speed {
                    GotoSpeed::Slow => f.goto_slow_deg_s,
                    GotoSpeed::Fast => f.goto_fast_deg_s,
                } * f.speed_factor;
                // A stalled axis never moves, so never finishes.
                a.goto = Some(SimGoto {
                    aim_deg: target_deg + f.goto_overshoot_deg.copysign(delta),
                    target_deg,
                    speed_deg_s: if f.stall { 0.0 } else { speed },
                });
                self.watch = Some(Watch {
                    axis,
                    next: now,
                    position_next: true,
                    finished: false,
                    last: None,
                });
            }
            _ => {}
        }
    }

    fn stop_axis(&mut self, axis: Axis) {
        let a = &mut self.axes[axis.index()];
        if a.goto.is_some() && self.faults.stop_ignores_goto {
            return;
        }
        a.goto = None;
        a.target_deg_s = 0.0;
    }

    /// A stop overtakes moves that haven't left yet, as the serial adapter's
    /// does: they are never sent, reach the motors or get acknowledged.
    fn cancel_unsent(&mut self, now: Nanos, axis: Option<Axis>) {
        let hit = |t: Nanos, a: Axis| t > now && axis.is_none_or(|x| x == a);
        let cancelled: Vec<CommandId> = self
            .sends
            .iter()
            .filter(|(t, _, a)| hit(*t, *a))
            .map(|(_, id, _)| *id)
            .collect();
        self.sends.retain(|(_, id, _)| !cancelled.contains(id));
        self.arriving
            .retain(|(_, c)| command_id(c).is_none_or(|id| !cancelled.contains(&id)));
        self.acks.retain(|(_, id)| !cancelled.contains(id));
    }

    /// False once the simulated link has dropped.
    pub fn is_connected(&self) -> bool {
        self.connected
    }

    pub fn angles_deg(&self) -> [f64; 2] {
        [self.axes[0].angle_deg, self.axes[1].angle_deg]
    }

    pub fn rates_deg_s(&self) -> [f64; 2] {
        [self.axes[0].rate_deg_s, self.axes[1].rate_deg_s]
    }

    /// The axis's position as its motor controller counts it (axis units).
    pub fn position_units(&self, axis: Axis) -> u32 {
        wrap_units(deg_to_units(self.axes[axis.index()].angle_deg))
    }

    /// The goto-finished flag: no goto is running on the axis.
    pub fn slew_done(&self, axis: Axis) -> bool {
        self.axes[axis.index()].goto.is_none()
    }

    /// What the phone would report now, or `None` once the IMU has stopped.
    /// Rates carry a little deterministic noise, like a real gyro.
    pub fn observation(&mut self, now: Nanos) -> Option<Observation> {
        if self
            .faults
            .imu_stops_at_ms
            .is_some_and(|t| now >= t as Nanos * MS)
        {
            return None;
        }
        let mut noise = || {
            self.noise = self
                .noise
                .wrapping_mul(6_364_136_223_846_793_005)
                .wrapping_add(1_442_695_040_888_963_407);
            ((self.noise >> 11) as f64 / (1u64 << 53) as f64 - 0.5) * 0.04
        };
        let rates = [
            self.axes[0].rate_deg_s + noise(),
            self.axes[1].rate_deg_s + noise(),
        ];
        Some(Observation {
            t_ns: now,
            rate_deg_s: rates,
            altitude_deg: self.start_altitude_deg + self.axes[1].angle_deg,
        })
    }
}

impl MountAdapter for SimMount {
    fn send(&mut self, command: &MountCommand, now: Nanos) -> Result<(), TransportError> {
        if !self.connected {
            return Err(TransportError("simulated link is down".into()));
        }
        self.received.push((now, command.clone()));
        let ignore_stop = self.faults.ignore_stop;
        match *command {
            MountCommand::Move { id, axis, .. } | MountCommand::Goto { id, axis, .. } => {
                let sent = now + self.faults.send_delay_ms as Nanos * MS;
                self.sends.push_back((sent, id, axis));
                if sent > now {
                    self.arriving.push((sent, command.clone()));
                } else {
                    self.arrive(command, now);
                }
                if !self.faults.drop_acks {
                    self.acks
                        .push_back((sent + self.faults.ack_delay_ms as Nanos * MS, id));
                }
            }
            MountCommand::Stop { axis } if !ignore_stop => {
                self.cancel_unsent(now, Some(axis));
                self.stop_axis(axis);
            }
            MountCommand::StopAll if !ignore_stop => {
                self.cancel_unsent(now, None);
                for axis in Axis::BOTH {
                    self.stop_axis(axis);
                }
            }
            _ => {}
        }
        Ok(())
    }

    fn poll(&mut self, now: Nanos) -> Vec<MountReport> {
        let mut reports = Vec::new();
        if self
            .faults
            .disconnect_at_ms
            .is_some_and(|t| now >= t as Nanos * MS)
        {
            self.connected = false;
            self.acks.clear();
            self.sends.clear();
            if !self.link_lost_reported {
                self.link_lost_reported = true;
                reports.push(MountReport::TransportLost);
            }
            return reports;
        }
        while self.sends.front().is_some_and(|(t, _, _)| *t <= now) {
            if let Some((sent_ns, id, _)) = self.sends.pop_front() {
                reports.push(MountReport::Sent { id, sent_ns });
            }
        }
        while self.acks.front().is_some_and(|(t, _)| *t <= now) {
            if let Some((_, id)) = self.acks.pop_front() {
                reports.push(MountReport::Acknowledged(id));
            }
        }
        if let Some(mut w) = self.watch.take() {
            if w.next <= now {
                w.next = now + READ_EVERY_MS as Nanos * MS;
                let axis = w.axis;
                if w.position_next {
                    let units = wrap_units(deg_to_units(self.axes[axis.index()].angle_deg));
                    reports.push(MountReport::Position {
                        axis,
                        t_ns: now,
                        units,
                    });
                    if w.finished && w.last == Some(units) {
                        return reports;
                    }
                    w.last = Some(units);
                } else {
                    let done = self.axes[axis.index()].goto.is_none();
                    w.finished |= done;
                    reports.push(MountReport::SlewDone {
                        axis,
                        t_ns: now,
                        done,
                    });
                }
                w.position_next = !w.position_next;
            }
            self.watch = Some(w);
        }
        reports
    }
}

fn command_id(command: &MountCommand) -> Option<CommandId> {
    match *command {
        MountCommand::Move { id, .. } | MountCommand::Goto { id, .. } => Some(id),
        _ => None,
    }
}
