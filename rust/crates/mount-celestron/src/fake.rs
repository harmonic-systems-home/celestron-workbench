//! A simulated hand controller in front of the simulated mount
//! ([`cwb_mount_sim::SimMount`]): it decodes the serial commands this
//! adapter sends and drives the simulated axes, so the simulator's fault
//! injection (ignored stops, reversal, stalls, a dropped link) applies to
//! the real adapter. It answers the preparation queries and `z` too.

use std::{
    collections::VecDeque,
    io,
    sync::{Arc, Mutex},
    time::Duration,
};

use cwb_celestron_discovery::Link;
use cwb_mount_core::{Axis, Direction, MountAdapter, MountCommand};
use cwb_mount_sim::SimMount;

use crate::adapter::Clock;

pub struct SimHandController {
    mount: Arc<Mutex<SimMount>>,
    clock: Clock,
    /// Tracking mode as `t` reports it; `T` sets it.
    pub tracking: u8,
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
        let motion = match *cmd {
            [b'P', 3, dev, dir @ (6 | 7), hi, lo, 0, 0] => axis(dev).map(|axis| {
                let units = u16::from_be_bytes([hi, lo]);
                if units == 0 {
                    MountCommand::Stop { axis }
                } else {
                    MountCommand::Move {
                        id: 0,
                        axis,
                        direction: if dir == 6 {
                            Direction::Positive
                        } else {
                            Direction::Negative
                        },
                        rate_deg_s: f64::from(units) / 4.0 / 3600.0,
                    }
                }
            }),
            [b'P', 2, dev, 36 | 37, 0, 0, 0, 0] => {
                axis(dev).map(|axis| MountCommand::Stop { axis })
            }
            _ => None,
        };
        if let Some(command) = motion {
            let now = (self.clock)();
            let mut mount = self.mount.lock().expect("sim mount");
            mount
                .send(&command, now)
                .map_err(|e| io::Error::new(io::ErrorKind::BrokenPipe, e.0))?;
            // The simulated mount's own acknowledgements aren't the serial
            // `#`; drop them.
            mount.poll(now);
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
