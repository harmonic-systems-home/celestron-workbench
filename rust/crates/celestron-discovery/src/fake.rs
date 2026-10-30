//! A simulated hand controller for tests and `--simulate` runs. It answers
//! only the catalog's queries, records every byte it receives, and stays
//! silent (a timeout) for anything else. All values are synthetic.

use std::{collections::VecDeque, io, time::Duration};

use crate::link::Link;

/// What the simulated hand controller reports.
#[derive(Debug, Clone)]
pub struct FakeSetup {
    pub version: (u8, u8),
    pub model: u8,
    /// `None`: the motor doesn't answer (pass-through error flag).
    pub motor_versions: [Option<(u8, u8)>; 2],
    pub aligned: bool,
    pub tracking_mode: u8,
    /// Axis angles as fractions of a revolution × 2³².
    pub position: [u32; 2],
    /// Anti-backlash settings: [azimuth, altitude] × [positive, negative].
    pub backlash: [[u8; 2]; 2],
    /// Added to the motor controllers' own positions (24 bits), against `z`'s.
    pub motor_offset: [i32; 2],
    /// Each motor controller's slew-done reply (0xFF done, 0x00 not).
    pub slew_done: [u8; 2],
    /// Added to each precise reading, cycling: encoder jitter.
    pub jitter: Vec<i32>,
    /// Answers nothing at all.
    pub silent: bool,
}

#[derive(Debug, Clone)]
pub struct FakeHandController {
    setup: FakeSetup,
    /// Every command received, in order.
    pub received: Vec<Vec<u8>>,
    pending: Vec<u8>,
    reply: VecDeque<u8>,
    readings: usize,
}

impl Default for FakeSetup {
    /// An Evolution-like controller; the version numbers are made up.
    fn default() -> Self {
        Self {
            version: (5, 34),
            model: 22,
            motor_versions: [Some((7, 11)), Some((7, 11))],
            aligned: false,
            tracking_mode: 0,
            position: [0x1234_5600, 0x0800_0000],
            backlash: [[0, 0], [0, 0]],
            motor_offset: [0, 0],
            slew_done: [0xFF, 0xFF],
            jitter: vec![0, 0x100, -0x100, 0],
            silent: false,
        }
    }
}

impl FakeHandController {
    pub fn new(setup: FakeSetup) -> Self {
        Self {
            setup,
            received: Vec::new(),
            pending: Vec::new(),
            reply: VecDeque::new(),
            readings: 0,
        }
    }

    /// Commands are 1, 2 or 8 bytes depending on the first.
    fn command_len(first: u8) -> usize {
        match first {
            b'K' => 2,
            b'P' => 8,
            _ => 1,
        }
    }

    fn answer(&mut self, cmd: &[u8]) -> Option<Vec<u8>> {
        let setup = &self.setup;
        let mut out = match cmd {
            [b'K', x] => vec![*x],
            [b'V'] => vec![setup.version.0, setup.version.1],
            [b'm'] => vec![setup.model],
            [b'J'] => vec![u8::from(setup.aligned)],
            [b'L'] => vec![b'0'],
            [b't'] => vec![setup.tracking_mode],
            [b'Z'] => format!(
                "{:04X},{:04X}",
                setup.position[0] >> 16,
                setup.position[1] >> 16
            )
            .into_bytes(),
            [b'z'] => {
                let j = if setup.jitter.is_empty() {
                    0
                } else {
                    setup.jitter[self.readings % setup.jitter.len()]
                };
                self.readings += 1;
                let azm = setup.position[0].wrapping_add_signed(j) & 0xFFFF_FF00;
                let alt = setup.position[1].wrapping_add_signed(-j) & 0xFFFF_FF00;
                format!("{azm:08X},{alt:08X}").into_bytes()
            }
            [b'P', 1, dev @ (16 | 17), id @ (0x40 | 0x41), 0, 0, 0, 1] => {
                vec![setup.backlash[usize::from(*dev - 16)][usize::from(*id - 0x40)]]
            }
            [b'P', 1, dev @ (16 | 17), 0x01, 0, 0, 0, 3] => {
                let axis = usize::from(*dev - 16);
                let units =
                    (setup.position[axis] >> 8).wrapping_add_signed(setup.motor_offset[axis]);
                units.to_be_bytes()[1..].to_vec()
            }
            [b'P', 1, dev @ (16 | 17), 0x13, 0, 0, 0, 1] => {
                vec![setup.slew_done[usize::from(*dev - 16)]]
            }
            [b'P', 1, dev @ (16 | 17), 254, 0, 0, 0, 2] => {
                match setup.motor_versions[usize::from(*dev - 16)] {
                    Some((major, minor)) => vec![major, minor],
                    // No answer from the device: one extra byte, data garbage.
                    None => vec![0, 0, 0],
                }
            }
            _ => return None,
        };
        out.push(b'#');
        Some(out)
    }
}

impl Link for FakeHandController {
    fn write_all(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.pending.extend_from_slice(bytes);
        while let Some(&first) = self.pending.first() {
            let len = Self::command_len(first);
            if self.pending.len() < len {
                break;
            }
            let cmd: Vec<u8> = self.pending.drain(..len).collect();
            self.received.push(cmd.clone());
            if !self.setup.silent
                && let Some(reply) = self.answer(&cmd)
            {
                self.reply.extend(reply);
            }
        }
        Ok(())
    }

    fn read_byte(&mut self, _timeout: Duration) -> io::Result<Option<u8>> {
        Ok(self.reply.pop_front())
    }

    fn discard_input(&mut self) -> io::Result<()> {
        self.reply.clear();
        Ok(())
    }
}
