//! Byte encodings for the commands this adapter may send, from the approved
//! discovery report (ADR 0010, "Proposed commands"): pass-through variable-
//! rate slews (`P 03 dev 06|07 hi lo 00 00`) and stops, each answered `#`.

use cwb_mount_core::{Axis, Direction, MountCommand};
use serde::{Deserialize, Serialize};

/// Pass-through bus addresses of the motor controllers.
pub fn device(axis: Axis) -> u8 {
    match axis {
        Axis::Azimuth => 16,
        Axis::Altitude => 17,
    }
}

const VARIABLE_POSITIVE: u8 = 6;
const VARIABLE_NEGATIVE: u8 = 7;
const FIXED_POSITIVE: u8 = 36;

/// How the adapter drives this mount (`[celestron]` in `config/mount.toml`).
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CelestronSettings {
    /// Which way the hand controller's "positive" slew turns each axis
    /// relative to the IMU's convention (azimuth clockwise from above,
    /// altitude up). Set by the axis-sign trial; a wrong sign shows up at
    /// once as opposite motion, which latches a fault.
    pub reverse_azimuth: bool,
    pub reverse_altitude: bool,
    /// How a move's own stop is sent (the stop-form trial). Stops after a
    /// fault, and on shutdown, always send both forms.
    #[serde(default)]
    pub stop: StopForm,
}

/// Which stop command ends a move.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum StopForm {
    /// Variable rate 0, then fixed rate 0.
    #[default]
    Both,
    /// Variable rate 0 only (the same mode as the slew).
    Variable,
    /// Fixed rate 0 only.
    Fixed,
}

impl CelestronSettings {
    fn reversed(self, axis: Axis) -> bool {
        match axis {
            Axis::Azimuth => self.reverse_azimuth,
            Axis::Altitude => self.reverse_altitude,
        }
    }
}

/// The variable rate's units: arcseconds per second × 4, 16 bits. Any
/// positive rate is at least one unit, so a move is never sent as rate 0.
pub fn rate_units(rate_deg_s: f64) -> u16 {
    (rate_deg_s * 3600.0 * 4.0)
        .round()
        .clamp(1.0, f64::from(u16::MAX)) as u16
}

/// The rate the hand controller will actually be asked for.
pub fn quantized_deg_s(rate_deg_s: f64) -> f64 {
    f64::from(rate_units(rate_deg_s)) / 4.0 / 3600.0
}

/// The serial transactions for one controller command, in order. A move's
/// own stop uses the configured [`StopForm`]; `StopAll` (faults, shutdown)
/// always sends a variable-rate 0 and then a fixed-rate 0 on each axis,
/// since which of them ends a variable-rate slew is still being observed
/// (ADR 0010, "To observe").
pub fn transactions(command: &MountCommand, signs: CelestronSettings) -> Vec<[u8; 8]> {
    match *command {
        MountCommand::Move {
            axis,
            direction,
            rate_deg_s,
            ..
        } => {
            let positive = (direction == Direction::Positive) != signs.reversed(axis);
            let [hi, lo] = rate_units(rate_deg_s).to_be_bytes();
            vec![[
                b'P',
                3,
                device(axis),
                if positive {
                    VARIABLE_POSITIVE
                } else {
                    VARIABLE_NEGATIVE
                },
                hi,
                lo,
                0,
                0,
            ]]
        }
        MountCommand::Stop { axis } => {
            let [variable, fixed] = stop(axis);
            match signs.stop {
                StopForm::Both => vec![variable, fixed],
                StopForm::Variable => vec![variable],
                StopForm::Fixed => vec![fixed],
            }
        }
        MountCommand::StopAll => Axis::BOTH.iter().flat_map(|a| stop(*a)).collect(),
    }
}

fn stop(axis: Axis) -> [[u8; 8]; 2] {
    let d = device(axis);
    [
        [b'P', 3, d, VARIABLE_POSITIVE, 0, 0, 0, 0],
        [b'P', 2, d, FIXED_POSITIVE, 0, 0, 0, 0],
    ]
}

/// Set Tracking Mode off (`T 00`): sent only during preparation, when the
/// hand controller reports tracking on, because slews conflict with it.
pub const TRACKING_OFF: [u8; 2] = [b'T', 0];
