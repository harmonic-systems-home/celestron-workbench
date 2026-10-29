//! The commands proposed for the hardware adapter (plan Prompt 8), each
//! mapped to its documentation or marked for hardware observation. These
//! are descriptions only: nothing in this crate can encode or send them.

use serde::Serialize;

#[derive(Debug, Clone, Copy, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Basis {
    /// In the Celestron protocol document, at the named section.
    Documented,
    /// Not documented: to be established by observation on the hardware.
    ObservationNeeded,
}

#[derive(Debug, Clone, Copy, Serialize)]
pub struct Proposed {
    pub purpose: &'static str,
    /// Bytes as sent, `hi lo` standing for the rate.
    pub bytes: &'static str,
    pub reply: &'static str,
    pub basis: Basis,
    pub source: &'static str,
    pub notes: &'static str,
}

pub const RATE_NOTE: &str = "Variable rate is arcseconds per second × 4 as a 16-bit value (high byte, low byte): steps of 0.25″/s (0.00007 °/s), up to 16383.75″/s (4.55 °/s). The safety configuration's 0.001–1 °/s is 14–14400.";

pub const PROPOSED: &[Proposed] = &[
    Proposed {
        purpose: "Move azimuth, positive, variable rate",
        bytes: "P 03 10 06 hi lo 00 00",
        reply: "#",
        basis: Basis::Documented,
        source: "Slewing Commands (1.6+)",
        notes: "Open-ended: the axis keeps moving until a stop arrives. The controller's lease sends the stop; a lost link leaves it moving (ADR 0005 layer 1: power switch).",
    },
    Proposed {
        purpose: "Move azimuth, negative, variable rate",
        bytes: "P 03 10 07 hi lo 00 00",
        reply: "#",
        basis: Basis::Documented,
        source: "Slewing Commands (1.6+)",
        notes: "As above.",
    },
    Proposed {
        purpose: "Move altitude, positive, variable rate",
        bytes: "P 03 11 06 hi lo 00 00",
        reply: "#",
        basis: Basis::Documented,
        source: "Slewing Commands (1.6+)",
        notes: "As above.",
    },
    Proposed {
        purpose: "Move altitude, negative, variable rate",
        bytes: "P 03 11 07 hi lo 00 00",
        reply: "#",
        basis: Basis::Documented,
        source: "Slewing Commands (1.6+)",
        notes: "As above.",
    },
    Proposed {
        purpose: "Stop one axis",
        bytes: "P 02 10 24 00 00 00 00 (azimuth), P 02 11 24 00 00 00 00 (altitude)",
        reply: "#",
        basis: Basis::Documented,
        source: "Slewing Commands: fixed rate \"0 to stop\" (1.6+)",
        notes: "Stop all = stop each axis in turn. Whether a fixed-rate stop also ends a variable-rate slew, and how quickly, is confirmed by observation in the first hardware trial.",
    },
    Proposed {
        purpose: "Acknowledgement",
        bytes: "(the reply to each command)",
        reply: "#",
        basis: Basis::Documented,
        source: "Slewing Commands; Developer Notes: Timeouts",
        notes: "`#` means the hand control relayed the command, not that the motor moved: motion is confirmed only by the IMU. Replies can take up to 3.5 s in the worst case; the reply latency check above compares observed latency with the 300 ms acknowledgement deadline.",
    },
    Proposed {
        purpose: "Read axis positions",
        bytes: "z",
        reply: "8 hex digits, comma, 8 hex digits, #",
        basis: Basis::Documented,
        source: "Get Position Commands (2.2+)",
        notes: "Fractions of a revolution; upper 24 bits used (0.077″). Relative to power-on until aligned. A second, independent motion record alongside the IMU.",
    },
    Proposed {
        purpose: "Turn tracking off before moves",
        bytes: "T 00",
        reply: "#",
        basis: Basis::Documented,
        source: "Tracking Commands: Set Tracking Mode (1.6+); Slewing Commands note",
        notes: "Slews conflict with tracking. Changes mount state but doesn't move it; sent only by the adapter, after arming.",
    },
    Proposed {
        purpose: "Precondition: no goto in progress",
        bytes: "L",
        reply: "ASCII 0 or 1, #",
        basis: Basis::Documented,
        source: "Miscellaneous Commands (1.2+)",
        notes: "Checked before arming.",
    },
];

/// Behaviour the documents don't settle, to observe in the first hardware
/// trials (Prompt 8), one at a time and with the operator at the power switch.
pub const TO_OBSERVE: &[&str] = &[
    "The slowest variable rate that actually turns each axis, and rate accuracy at the low rates the tests use.",
    "Time from the `#` reply to motion the IMU sees (onset), and from a stop's `#` to stillness (stop delay and coast).",
    "Whether a fixed-rate stop (rate 0) ends a variable-rate slew; if not, whether variable rate 0 does.",
    "Whether hand controller keypad presses interrupt or override a serial slew.",
    "Whether Celestron's own slew limits apply to pass-through slews (ADR 0005 layer 2).",
    "What an active slew does when the serial link drops mid-move (expected: keeps moving).",
];
