//! The motor controllers' anti-backlash settings (0–99 per axis and
//! direction). Not in Celestron's document: the commands are libnexstar's
//! `tc_get_backlash` (`P 01 dev 40|41 00 00 00 01`) and `tc_set_backlash`
//! (`P 02 dev 10|11 value 00 00 00`), pass-through to the motor controller.
//! Every set is read back. Finding and writing the right values is one of
//! this project's outputs (ADR 0011).

use std::fmt;

use cwb_celestron_discovery::{
    Link, Outcome, Query,
    query::{Device, Sense, Value},
    transact,
};

use crate::apply::{Applied, ReadBack};

/// The highest value the hand controller accepts.
pub const MAX: u8 = 99;

const SET_POSITIVE: u8 = 0x10;
const SET_NEGATIVE: u8 = 0x11;

/// One of the four settings.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct Slot {
    pub device: Device,
    pub sense: Sense,
}

impl Slot {
    pub const ALL: [Slot; 4] = [
        Slot::new(Device::AzmMotor, Sense::Positive),
        Slot::new(Device::AzmMotor, Sense::Negative),
        Slot::new(Device::AltMotor, Sense::Positive),
        Slot::new(Device::AltMotor, Sense::Negative),
    ];

    pub const fn new(device: Device, sense: Sense) -> Self {
        Self { device, sense }
    }

    /// `azm+`, `azm-`, `alt+` or `alt-`.
    pub fn parse(text: &str) -> Option<Self> {
        Some(match text {
            "azm+" | "az+" => Slot::ALL[0],
            "azm-" | "az-" => Slot::ALL[1],
            "alt+" => Slot::ALL[2],
            "alt-" => Slot::ALL[3],
            _ => return None,
        })
    }

    pub fn get_bytes(self) -> Vec<u8> {
        Query::Backlash(self.device, self.sense).bytes()
    }

    pub fn set_bytes(self, value: u8) -> [u8; 8] {
        let id = match self.sense {
            Sense::Positive => SET_POSITIVE,
            Sense::Negative => SET_NEGATIVE,
        };
        [b'P', 2, self.device.id(), id, value, 0, 0, 0]
    }
}

impl fmt::Display for Slot {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}{}",
            match self.device {
                Device::AzmMotor => "azm",
                Device::AltMotor => "alt",
            },
            match self.sense {
                Sense::Positive => "+",
                Sense::Negative => "-",
            }
        )
    }
}

/// Reads one setting; `None` when it went unanswered.
pub fn read(link: &mut impl Link, slot: Slot) -> Option<u8> {
    let query = Query::Backlash(slot.device, slot.sense);
    let (outcome, reply) = transact(link, &query.bytes(), 1, true);
    match (outcome, query.decode(reply.get(..1)?)) {
        (Outcome::Ok, Some(Value::Backlash(v))) => Some(v),
        _ => None,
    }
}

/// Sets one value (at most [`MAX`]) and reads it back.
pub fn set(link: &mut impl Link, slot: Slot, value: u8) -> Applied {
    assert!(value <= MAX, "backlash values are 0–{MAX}");
    let (acknowledged, _) = transact(link, &slot.set_bytes(value), 0, true);
    if acknowledged != Outcome::Ok {
        return Applied {
            acknowledged,
            read_back: None,
        };
    }
    let read_back = match read(link, slot) {
        Some(v) if v == value => ReadBack::Matches,
        Some(v) => ReadBack::Differs(format!("{slot} reads back {v}, not {value}")),
        None => ReadBack::NotAnswered(Outcome::Timeout),
    };
    Applied {
        acknowledged,
        read_back: Some(read_back),
    }
}
