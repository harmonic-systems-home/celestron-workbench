//! Byte encodings for the commands this adapter may send, from the approved
//! discovery report (ADR 0010, "Proposed commands"): pass-through variable-
//! rate slews (`P 03 dev 06|07 hi lo 00 00`, never rate 0) and stops (`T 00`
//! and fixed rate 0), each answered `#`; and gotos by motor position (ADR
//! 0014, `P 04 dev 02|17 HH MM LL 00`).

use cwb_mount_core::{Axis, Direction, GotoSpeed, MountCommand, wrap_units};
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
pub const GOTO_FAST: u8 = 0x02;
pub const GOTO_SLOW: u8 = 0x17;

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
}

impl CelestronSettings {
    fn reversed(self, axis: Axis) -> bool {
        match axis {
            Axis::Azimuth => self.reverse_azimuth,
            Axis::Altitude => self.reverse_altitude,
        }
    }

    /// Converts a position between the motor controller's count and axis
    /// units (positive as the IMU sees it); the same either way.
    pub fn flip_units(self, axis: Axis, units: u32) -> u32 {
        if self.reversed(axis) {
            wrap_units(-i64::from(units))
        } else {
            units
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

/// One serial command: pass-through to a motor controller, or to the hand
/// controller itself. Every one is answered `#`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Tx {
    pub bytes: Vec<u8>,
    pub pass_through: bool,
}

/// The serial transactions for one controller command, in order.
///
/// A stop is `T 00` (tracking off) and then fixed rate 0 on the axis.
/// Variable-rate commands set the motor controllers' guide/tracking rate:
/// on these controllers (7.17) "variable rate 0" doesn't stop, it creeps at
/// the slowest rate, and fixed rate 0 doesn't cancel it; tracking off does
/// (docs/observations.md, O1). Tracking off is mount-wide, which is fine:
/// only one axis ever moves. The fixed rate 0 covers anything in fixed-rate
/// mode. Variable rate 0 is never sent.
pub fn transactions(command: &MountCommand, signs: CelestronSettings) -> Vec<Tx> {
    match *command {
        MountCommand::Move {
            axis,
            direction,
            rate_deg_s,
            ..
        } => {
            let positive = (direction == Direction::Positive) != signs.reversed(axis);
            let [hi, lo] = rate_units(rate_deg_s).to_be_bytes();
            vec![motor([
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
            ])]
        }
        MountCommand::Goto {
            axis,
            target,
            speed,
            ..
        } => {
            vec![goto_motor(axis, signs.flip_units(axis, target), speed)]
        }
        MountCommand::Stop { axis } => vec![tracking_off(), fixed_zero(axis)],
        MountCommand::StopAll => vec![
            tracking_off(),
            fixed_zero(Axis::Azimuth),
            fixed_zero(Axis::Altitude),
        ],
    }
}

/// A goto to `motor_units`, as the motor controller counts.
pub fn goto_motor(axis: Axis, motor_units: u32, speed: GotoSpeed) -> Tx {
    let [_, hh, mm, ll] = motor_units.to_be_bytes();
    let message = match speed {
        GotoSpeed::Fast => GOTO_FAST,
        GotoSpeed::Slow => GOTO_SLOW,
    };
    motor([b'P', 4, device(axis), message, hh, mm, ll, 0])
}

fn motor(bytes: [u8; 8]) -> Tx {
    Tx {
        bytes: bytes.to_vec(),
        pass_through: true,
    }
}

fn tracking_off() -> Tx {
    Tx {
        bytes: TRACKING_OFF.to_vec(),
        pass_through: false,
    }
}

fn fixed_zero(axis: Axis) -> Tx {
    motor([b'P', 2, device(axis), FIXED_POSITIVE, 0, 0, 0, 0])
}

/// Set Tracking Mode off (`T 00`): the stop for a variable-rate move, and
/// sent during preparation to clear any rate left over from earlier.
pub const TRACKING_OFF: [u8; 2] = [b'T', 0];
