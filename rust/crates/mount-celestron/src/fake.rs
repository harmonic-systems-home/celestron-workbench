//! A simulated hand controller in front of the simulated mount
//! ([`cwb_mount_sim::SimMount`]): it decodes the serial commands this
//! adapter sends and drives the simulated axes, so the simulator's fault
//! injection (ignored stops, reversal, stalls, a dropped link) applies to
//! the real adapter. It answers the preparation queries and `z` too.
//!
//! It behaves like the Evolution's motor controllers did on 2026-10-29
//! (docs/observations.md, O1): a variable-rate command sets a rate that
//! fixed-rate commands don't cancel; variable rate 0 creeps at the slowest
//! rate (+0.21″/s, −0.36″/s); tracking off (`T 00`) stops it. Gotos by
//! position (`P 04 dev 02|17 HH MM LL 00`) run on the simulated mount; as
//! on the mount, neither tracking off nor fixed rate 0 ends one, and a new
//! goto re-aims it (O11). The motor controllers' position and goto-finished
//! flag are answered too.

use std::{
    collections::VecDeque,
    io,
    sync::{Arc, Mutex},
    time::Duration,
};

use cwb_celestron_discovery::Link;
use cwb_mount_core::{Axis, Direction, GotoSpeed, MountAdapter, MountCommand};
use cwb_mount_sim::SimMount;

use crate::adapter::Clock;

/// The slowest variable rates, which "variable rate 0" runs at.
pub const CREEP_POSITIVE_ARCSEC_S: f64 = 0.21;
pub const CREEP_NEGATIVE_ARCSEC_S: f64 = 0.358;

pub struct SimHandController {
    mount: Arc<Mutex<SimMount>>,
    clock: Clock,
    /// Tracking mode as `t` reports it; `T` sets it.
    pub tracking: u8,
    /// A variable rate is set on the axis (`Axis::index`).
    variable: [bool; 2],
    /// Every anti-backlash setting reads as this.
    pub backlash: u8,
    /// Every command received, shared so tests can read it after the
    /// adapter has taken the link.
    pub received: Arc<Mutex<Vec<Vec<u8>>>>,
    pending: Vec<u8>,
    reply: VecDeque<u8>,
}

impl SimHandController {
    pub fn new(mount: Arc<Mutex<SimMount>>, clock: Clock) -> Self {
        Self {
            mount,
            clock,
            tracking: 0,
            variable: [false; 2],
            backlash: 0,
            received: Arc::default(),
            pending: Vec::new(),
            reply: VecDeque::new(),
        }
    }

    fn command_len(first: u8) -> usize {
        match first {
            b'K' | b'T' => 2,
            b'P' => 8,
            _ => 1,
        }
    }

    /// The reply payload, or `None` for no answer. `Err` when the
    /// simulated link is down.
    fn answer(&mut self, cmd: &[u8]) -> io::Result<Option<Vec<u8>>> {
        let axis = |dev: u8| match dev {
            16 => Some(Axis::Azimuth),
            17 => Some(Axis::Altitude),
            _ => None,
        };
        let mv = |axis, positive: bool, rate_deg_s| MountCommand::Move {
            id: 0,
            axis,
            direction: if positive {
                Direction::Positive
            } else {
                Direction::Negative
            },
            rate_deg_s,
        };
        let motion: Vec<MountCommand> = match *cmd {
            [b'P', 3, dev, dir @ (6 | 7), hi, lo, 0, 0] => axis(dev)
                .map(|axis| {
                    self.variable[axis.index()] = true;
                    let units = u16::from_be_bytes([hi, lo]);
                    let rate = if units > 0 {
                        f64::from(units) / 4.0 / 3600.0
                    } else if dir == 6 {
                        CREEP_POSITIVE_ARCSEC_S / 3600.0
                    } else {
                        CREEP_NEGATIVE_ARCSEC_S / 3600.0
                    };
                    mv(axis, dir == 6, rate)
                })
                .into_iter()
                .collect(),
            // Neither ends a goto (O11): only a new goto re-aims it.
            [b'P', 2, dev, dir @ (36 | 37), rate, 0, 0, 0] => axis(dev)
                .filter(|axis| {
                    !self.variable[axis.index()]
                        && self.mount.lock().expect("sim mount").slew_done(*axis)
                })
                .map(|axis| match rate {
                    0 => MountCommand::Stop { axis },
                    // Fixed rate 1, about twice sidereal.
                    _ => mv(axis, dir == 36, 0.0084),
                })
                .into_iter()
                .collect(),
            [b'P', 4, dev, message @ (0x02 | 0x17), hh, mm, ll, 0] => axis(dev)
                .map(|axis| {
                    self.variable[axis.index()] = false;
                    MountCommand::Goto {
                        id: 0,
                        axis,
                        target: u32::from_be_bytes([0, hh, mm, ll]),
                        speed: if message == 0x02 {
                            GotoSpeed::Fast
                        } else {
                            GotoSpeed::Slow
                        },
                    }
                })
                .into_iter()
                .collect(),
            [b'T', _] => Axis::BOTH
                .into_iter()
                .filter(|a| std::mem::take(&mut self.variable[a.index()]))
                .map(|axis| MountCommand::Stop { axis })
                .collect(),
            _ => Vec::new(),
        };
        if !motion.is_empty() {
            let now = (self.clock)();
            let mut mount = self.mount.lock().expect("sim mount");
            for command in &motion {
                mount
                    .send(command, now)
                    .map_err(|e| io::Error::new(io::ErrorKind::BrokenPipe, e.0))?;
            }
            // The simulated mount's own acknowledgements aren't the serial
            // `#`; drop them.
            mount.poll(now);
            if let [b'T', mode] = *cmd {
                self.tracking = mode;
            }
            return Ok(Some(Vec::new()));
        }
        if matches!(*cmd, [b'P', 2, 16 | 17, 36 | 37, _, 0, 0, 0]) {
            // A fixed-rate command to an axis with a variable rate: answered,
            // but it changes nothing.
            return Ok(Some(Vec::new()));
        }
        if !self.mount.lock().expect("sim mount").is_connected() {
            return Err(io::Error::new(
                io::ErrorKind::BrokenPipe,
                "simulated link is down",
            ));
        }
        Ok(Some(match *cmd {
            [b'K', x] => vec![x],
            [b'V'] => vec![1, 22],
            [b'm'] => vec![22],
            [b'P', 1, 16 | 17, 254, 0, 0, 0, 2] => vec![7, 17],
            [b'P', 1, 16 | 17, 0x40 | 0x41, 0, 0, 0, 1] => vec![self.backlash],
            [b'P', 1, dev @ (16 | 17), 0x01, 0, 0, 0, 3] => {
                // About the 12 bytes' time on the wire at 9600 baud, so a
                // goto watch's readings are spread out as on the mount.
                std::thread::sleep(Duration::from_millis(10));
                let axis = axis(dev).expect("motor");
                let units = self.mount.lock().expect("sim mount").position_units(axis);
                units.to_be_bytes()[1..].to_vec()
            }
            [b'P', 1, dev @ (16 | 17), 0x13, 0, 0, 0, 1] => {
                let axis = axis(dev).expect("motor");
                let done = self.mount.lock().expect("sim mount").slew_done(axis);
                vec![if done { 0xFF } else { 0x00 }]
            }
            [b'L'] => vec![b'0'],
            [b't'] => vec![self.tracking],
            [b'T', mode] => {
                self.tracking = mode;
                Vec::new()
            }
            [b'z'] => {
                let deg = self.mount.lock().expect("sim mount").angles_deg();
                let raw = deg
                    .map(|d| ((d / 360.0).rem_euclid(1.0) * 4_294_967_296.0) as u32 & 0xFFFF_FF00);
                format!("{:08X},{:08X}", raw[0], raw[1]).into_bytes()
            }
            _ => return Ok(None),
        }))
    }
}

impl Link for SimHandController {
    fn write_all(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.pending.extend_from_slice(bytes);
        while let Some(&first) = self.pending.first() {
            let len = Self::command_len(first);
            if self.pending.len() < len {
                break;
            }
            let cmd: Vec<u8> = self.pending.drain(..len).collect();
            self.received.lock().expect("received").push(cmd.clone());
            if let Some(mut reply) = self.answer(&cmd)? {
                reply.push(b'#');
                self.reply.extend(reply);
            }
        }
        Ok(())
    }

    fn read_byte(&mut self, timeout: Duration) -> io::Result<Option<u8>> {
        let byte = self.reply.pop_front();
        if byte.is_none() {
            // A real link waits out the timeout; keep tests honest but quick.
            std::thread::sleep(timeout.min(Duration::from_millis(5)));
        }
        Ok(byte)
    }

    fn discard_input(&mut self) -> io::Result<()> {
        self.reply.clear();
        Ok(())
    }
}
