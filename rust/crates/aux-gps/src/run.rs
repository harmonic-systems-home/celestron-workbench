//! The test: for a set time, push the GPS replies a hand controller would
//! ask for, every so often, and answer any GPS request heard on the bus.
//! Reports what was sent and heard; deciding whether the hand controller
//! took the values is for its display and the AUX Listener's log.

use std::{collections::BTreeMap, io, time::Duration};

use crate::{
    gps::{self, Clock, Fix, GPS, Utc},
    link::Link,
    packet::{Framer, Packet},
};

#[derive(Debug, Clone)]
pub struct Plan {
    pub hand_controller: u8,
    pub clock: Clock,
    /// Push the whole sequence this often; `None` only answers requests.
    pub push_every: Option<Duration>,
    /// Pause between pushed packets, so the bus isn't flooded.
    pub gap: Duration,
    pub duration: Duration,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Event {
    /// Sent unasked.
    Pushed(Packet),
    /// A GPS request heard, and the reply sent (`None`: not one we answer).
    Answered {
        request: Packet,
        reply: Option<Packet>,
    },
    /// Our own packet coming back from the Wi-Fi module.
    Echo(Packet),
    /// Anything else heard.
    Heard(Packet),
}

#[derive(Debug, Default, Clone, PartialEq)]
pub struct Summary {
    pub pushed: usize,
    pub echoed: usize,
    /// GPS requests heard, by (asker, message ID).
    pub gps_requests: BTreeMap<(u8, u8), usize>,
    pub answered: usize,
    /// Packets from the hand controller, to anyone.
    pub from_hand_controller: usize,
    /// Packets from 0xB0 that we didn't send: another GPS on the bus.
    pub other_gps: usize,
}

/// Runs the test. `elapsed` gives the time since the start, `wall` the
/// current UTC time (used only with [`Clock::Now`]).
pub fn run<L: Link>(
    link: &mut L,
    plan: &Plan,
    elapsed: &mut dyn FnMut() -> Duration,
    wall: &mut dyn FnMut() -> Utc,
    on_event: &mut dyn FnMut(&Event),
) -> io::Result<Summary> {
    let mut summary = Summary::default();
    let mut framer = Framer::default();
    let mut sent: Vec<Vec<u8>> = Vec::new();
    let mut next_push = Duration::ZERO;
    let hc = plan.hand_controller;
    let fix = |wall: &mut dyn FnMut() -> Utc| match plan.clock {
        Clock::Fixed(t) => Fix::at(t),
        Clock::Now => Fix::at(wall()),
    };

    loop {
        let now = elapsed();
        if now >= plan.duration {
            break;
        }
        if let Some(every) = plan.push_every
            && now >= next_push
        {
            let f = fix(wall);
            for id in gps::PUSH_SEQUENCE {
                let p = f.packet(id, hc).expect("push IDs all have replies");
                let bytes = p.encode();
                link.send(&bytes)?;
                sent.push(bytes);
                summary.pushed += 1;
                on_event(&Event::Pushed(p));
                if !plan.gap.is_zero() {
                    std::thread::sleep(plan.gap);
                }
            }
            next_push = now + every;
        }
        let bytes = link.recv(Duration::from_millis(100))?;
        for p in framer.push(&bytes) {
            if p.src == hc {
                summary.from_hand_controller += 1;
            }
            if p.src == GPS {
                let enc = p.encode();
                if let Some(i) = sent.iter().position(|s| *s == enc) {
                    sent.remove(i);
                    summary.echoed += 1;
                    on_event(&Event::Echo(p));
                } else {
                    summary.other_gps += 1;
                    on_event(&Event::Heard(p));
                }
            } else if p.dst == GPS {
                *summary.gps_requests.entry((p.src, p.id)).or_default() += 1;
                let reply = fix(wall).packet(p.id, p.src);
                if let Some(r) = &reply {
                    let bytes = r.encode();
                    link.send(&bytes)?;
                    sent.push(bytes);
                    summary.answered += 1;
                }
                on_event(&Event::Answered { request: p, reply });
            } else {
                on_event(&Event::Heard(p));
            }
        }
        // Keep only recent sends for echo matching.
        if sent.len() > 64 {
            sent.drain(..sent.len() - 64);
        }
    }
    Ok(summary)
}
