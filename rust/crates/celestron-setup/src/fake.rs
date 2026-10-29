//! A simulated hand controller for the setters: it keeps whatever time and
//! location it is sent and returns them on read-back, and answers the echo
//! and model queries the CLI checks first. Anything else gets no answer (a
//! timeout).

use std::{collections::VecDeque, io, time::Duration};

use cwb_celestron_discovery::Link;

use crate::command::{GET_LOCATION, GET_TIME, SET_LOCATION, SET_TIME};

/// How the simulated hand controller misbehaves, if at all.
#[derive(Debug, Clone, Default)]
pub struct Quirks {
    /// Seconds added to the stored time on read-back: a drifting clock.
    pub clock_offset_s: u8,
    /// Acknowledges sets but doesn't store them.
    pub forgets: bool,
    /// Answers nothing.
    pub silent: bool,
}

#[derive(Debug, Default)]
pub struct FakeSetter {
    quirks: Quirks,
    pub time: Option<[u8; 8]>,
    pub location: Option<[u8; 8]>,
    /// Anti-backlash: [azimuth, altitude] × [positive, negative].
    pub backlash: [[u8; 2]; 2],
    /// Every command received, in order.
    pub received: Vec<Vec<u8>>,
    pending: Vec<u8>,
    reply: VecDeque<u8>,
}

impl FakeSetter {
    pub fn new(quirks: Quirks) -> Self {
        Self {
            quirks,
            ..Self::default()
        }
    }

    fn answer(&mut self, cmd: &[u8]) -> Option<Vec<u8>> {
        let mut out = match cmd[0] {
            SET_TIME => {
                if !self.quirks.forgets {
                    self.time = cmd[1..].try_into().ok();
                }
                Vec::new()
            }
            SET_LOCATION => {
                if !self.quirks.forgets {
                    self.location = cmd[1..].try_into().ok();
                }
                Vec::new()
            }
            GET_TIME => {
                let mut t = self.time.unwrap_or([0, 0, 0, 1, 1, 0, 0, 0]);
                t[2] = t[2].saturating_add(self.quirks.clock_offset_s);
                t.to_vec()
            }
            GET_LOCATION => self.location.unwrap_or_default().to_vec(),
            b'P' => match *cmd {
                [_, 1, dev @ (16 | 17), id @ (0x40 | 0x41), 0, 0, 0, 1] => {
                    vec![self.backlash[usize::from(dev - 16)][usize::from(id - 0x40)]]
                }
                [_, 2, dev @ (16 | 17), id @ (0x10 | 0x11), value, 0, 0, 0] => {
                    if !self.quirks.forgets {
                        self.backlash[usize::from(dev - 16)][usize::from(id - 0x10)] = value;
                    }
                    Vec::new()
                }
                _ => return None,
            },
            b'K' => vec![cmd[1]],
            // NexStar Evolution.
            b'm' => vec![22],
            _ => return None,
        };
        out.push(b'#');
        Some(out)
    }
}

impl Link for FakeSetter {
    fn write_all(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.pending.extend_from_slice(bytes);
        while let Some(&first) = self.pending.first() {
            let len = match first {
                SET_TIME | SET_LOCATION => 9,
                b'P' => 8,
                b'K' => 2,
                _ => 1,
            };
            if self.pending.len() < len {
                break;
            }
            let cmd: Vec<u8> = self.pending.drain(..len).collect();
            self.received.push(cmd.clone());
            if !self.quirks.silent
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
