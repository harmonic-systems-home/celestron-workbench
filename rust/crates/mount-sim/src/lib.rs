//! A deterministic two-axis mount and IMU simulator with fault injection
//! (plan Prompt 6, ADR 0005), and a harness that runs scripted scenarios
//! against the interlock [`Controller`]. Nothing here touches hardware.
//!
//! The simulated mount accelerates each axis toward its commanded rate,
//! acknowledges commands after a delay, and can misbehave on request:
//! delayed or missing acknowledgements, ignored stops, motion opposite to
//! the command, stalls, overspeed, a dropped link (with the axes still
//! turning, the worst case), a silent IMU, and an external bump.

pub mod harness;

use std::collections::VecDeque;

use cwb_mount_core::{
    Axis, CommandId, MountAdapter, MountCommand, MountReport, Nanos, Observation, TransportError,
};

const MS: Nanos = 1_000_000;

/// Faults to inject. The default is a well-behaved mount.
#[derive(Debug, Clone, PartialEq)]
pub struct SimFaults {
    /// Time from command to acknowledgement.
    pub ack_delay_ms: u64,
    /// A move reaches the motors this long after it was handed over, as when
    /// a serial adapter is mid-way through a position read. Its
    /// acknowledgement reports the later send time.
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
        }
    }
}

#[derive(Debug, Clone, Copy, Default, PartialEq)]
struct SimAxis {
    target_deg_s: f64,
    rate_deg_s: f64,
    angle_deg: f64,
}

pub struct SimMount {
    faults: SimFaults,
    axes: [SimAxis; 2],
    connected: bool,
    link_lost_reported: bool,
    /// Due time, command, and when it was sent.
    acks: VecDeque<(Nanos, CommandId, Nanos)>,
    /// Moves on their way to the motors: when they arrive, axis, target rate.
    arriving: Vec<(Nanos, Axis, f64)>,
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
            arriving: Vec::new(),
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
        self.arriving.retain(|(at, axis, target)| {
            if *at <= now {
                self.axes[axis.index()].target_deg_s = *target;
            }
            *at > now
        });
        let dt = dt_ns as f64 / 1e9;
        let max_change = self.accel_deg_s2 * dt;
        for (i, axis) in self.axes.iter_mut().enumerate() {
            let mut target = axis.target_deg_s;
            if let Some((bumped, rate, from, to)) = self.faults.bump
                && bumped.index() == i
                && (from as Nanos * MS..to as Nanos * MS).contains(&now)
            {
                target += rate;
            }
            let change = (target - axis.rate_deg_s).clamp(-max_change, max_change);
            axis.rate_deg_s += change;
            axis.angle_deg += axis.rate_deg_s * dt;
        }
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
            MountCommand::Move {
                id,
                axis,
                direction,
                rate_deg_s,
            } => {
                let sign = direction.sign() * if self.faults.reverse { -1.0 } else { 1.0 };
                let sent = now + self.faults.send_delay_ms as Nanos * MS;
                if !self.faults.stall {
                    let target = sign * rate_deg_s * self.faults.speed_factor;
                    if sent > now {
                        self.arriving.push((sent, axis, target));
                    } else {
                        self.axes[axis.index()].target_deg_s = target;
                    }
                }
                if !self.faults.drop_acks {
                    self.acks
                        .push_back((sent + self.faults.ack_delay_ms as Nanos * MS, id, sent));
                }
            }
            MountCommand::Stop { axis } if !ignore_stop => {
                self.arriving.retain(|(_, a, _)| *a != axis);
                self.axes[axis.index()].target_deg_s = 0.0;
            }
            MountCommand::StopAll if !ignore_stop => {
                self.arriving.clear();
                for axis in &mut self.axes {
                    axis.target_deg_s = 0.0;
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
            if !self.link_lost_reported {
                self.link_lost_reported = true;
                reports.push(MountReport::TransportLost);
            }
            return reports;
        }
        while self.acks.front().is_some_and(|(t, _, _)| *t <= now) {
            if let Some((_, id, sent_ns)) = self.acks.pop_front() {
                reports.push(MountReport::Acknowledged { id, sent_ns });
            }
        }
        reports
    }
}
