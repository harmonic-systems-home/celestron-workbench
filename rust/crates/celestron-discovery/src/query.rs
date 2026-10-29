//! The read-only query catalog: the only bytes discovery can send.
//!
//! Every query here is a documented non-motion "get" command from
//! Celestron's hand control serial protocol ([`REFERENCE`]). Nothing that
//! moves the mount, starts a goto, syncs, or sets tracking, time or location
//! can be expressed: there is no variant for it and no way to send raw bytes.

use std::fmt;

use serde::Serialize;

pub const REFERENCE: &str =
    "Celestron, NexStar Communication Protocol (hand control serial commands)";
pub const REFERENCE_URL: &str = "https://s3.amazonaws.com/celestron-site-support-files/support_files/1154108406_nexstarcommprot.pdf";
/// Community source for model codes newer than the Celestron document.
pub const LIBNEXSTAR_URL: &str = "https://github.com/indigo-astronomy/libnexstar";

/// The hand control may retry internally; drivers should wait this long.
pub const REPLY_TIMEOUT_MS: u64 = 3_500;

/// Devices on the mount's bus, as pass-through destinations.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Device {
    AzmMotor,
    AltMotor,
}

impl Device {
    pub fn id(self) -> u8 {
        match self {
            Device::AzmMotor => 16,
            Device::AltMotor => 17,
        }
    }
}

/// Which way a backlash setting applies: when the axis turns to positive,
/// or to negative.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Sense {
    Positive,
    Negative,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Query {
    /// Returns the byte sent; checks the link.
    Echo(u8),
    /// Hand controller firmware.
    Version,
    Model,
    AlignmentComplete,
    GotoInProgress,
    TrackingMode,
    /// 16-bit axis angles.
    AzmAlt,
    /// 32-bit axis angles (upper 24 bits used).
    PreciseAzmAlt,
    /// Motor controller firmware, by pass-through.
    DeviceVersion(Device),
    /// A motor controller's anti-backlash setting (0–99), by pass-through.
    /// Not in Celestron's document: from libnexstar's `tc_get_backlash`.
    Backlash(Device, Sense),
}

/// Pass-through message ID for "get version".
pub const GET_DEVICE_VERSION: u8 = 254;
/// Pass-through message IDs for "get backlash" (libnexstar).
pub const GET_BACKLASH_POSITIVE: u8 = 0x40;
pub const GET_BACKLASH_NEGATIVE: u8 = 0x41;

impl Sense {
    pub fn get_id(self) -> u8 {
        match self {
            Sense::Positive => GET_BACKLASH_POSITIVE,
            Sense::Negative => GET_BACKLASH_NEGATIVE,
        }
    }
}

impl Query {
    pub fn bytes(self) -> Vec<u8> {
        match self {
            Query::Echo(x) => vec![b'K', x],
            Query::Version => vec![b'V'],
            Query::Model => vec![b'm'],
            Query::AlignmentComplete => vec![b'J'],
            Query::GotoInProgress => vec![b'L'],
            Query::TrackingMode => vec![b't'],
            Query::AzmAlt => vec![b'Z'],
            Query::PreciseAzmAlt => vec![b'z'],
            Query::DeviceVersion(d) => vec![b'P', 1, d.id(), GET_DEVICE_VERSION, 0, 0, 0, 2],
            Query::Backlash(d, sense) => vec![b'P', 1, d.id(), sense.get_id(), 0, 0, 0, 1],
        }
    }

    /// Reply payload length, before the `#` terminator.
    pub fn reply_len(self) -> usize {
        match self {
            Query::Version | Query::DeviceVersion(_) => 2,
            Query::AzmAlt => 9,
            Query::PreciseAzmAlt => 17,
            _ => 1,
        }
    }

    /// Pass-through commands flag a missing device with one extra byte.
    pub fn is_pass_through(self) -> bool {
        matches!(self, Query::DeviceVersion(_) | Query::Backlash(..))
    }

    /// Lowest hand control version the document lists for this command.
    pub fn since_version(self) -> (u8, u8) {
        match self {
            Query::Echo(_)
            | Query::Version
            | Query::AlignmentComplete
            | Query::GotoInProgress
            | Query::AzmAlt => (1, 2),
            Query::DeviceVersion(_) | Query::Backlash(..) => (1, 6),
            Query::Model | Query::PreciseAzmAlt => (2, 2),
            Query::TrackingMode => (2, 3),
        }
    }

    /// Where the command is documented in [`REFERENCE`].
    pub fn reference(self) -> &'static str {
        match self {
            Query::AzmAlt | Query::PreciseAzmAlt => "Get Position Commands",
            Query::TrackingMode => "Tracking Commands: Get Tracking Mode",
            Query::Backlash(..) => "libnexstar tc_get_backlash (not in Celestron's document)",
            _ => "Miscellaneous Commands",
        }
    }

    pub fn decode(self, payload: &[u8]) -> Option<Value> {
        if payload.len() != self.reply_len() {
            return None;
        }
        Some(match self {
            Query::Echo(_) => Value::Echo(payload[0]),
            Query::Version | Query::DeviceVersion(_) => Value::Version {
                major: payload[0],
                minor: payload[1],
            },
            Query::Model => Value::Model(payload[0]),
            Query::AlignmentComplete => Value::Flag(payload[0] == 1),
            // The document says ASCII "0" or "1" here, unlike `J`.
            Query::GotoInProgress => match payload[0] {
                b'0' => Value::Flag(false),
                b'1' => Value::Flag(true),
                _ => return None,
            },
            Query::TrackingMode => Value::TrackingMode(payload[0]),
            Query::Backlash(..) => Value::Backlash(payload[0]),
            Query::AzmAlt => parse_angles(payload, 4)?,
            Query::PreciseAzmAlt => parse_angles(payload, 8)?,
        })
    }
}

impl fmt::Display for Query {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Query::Echo(x) => write!(f, "echo {:?}", *x as char),
            Query::Version => f.write_str("hand controller version"),
            Query::Model => f.write_str("model"),
            Query::AlignmentComplete => f.write_str("alignment complete?"),
            Query::GotoInProgress => f.write_str("goto in progress?"),
            Query::TrackingMode => f.write_str("tracking mode"),
            Query::AzmAlt => f.write_str("azm-alt position"),
            Query::PreciseAzmAlt => f.write_str("precise azm-alt position"),
            Query::DeviceVersion(Device::AzmMotor) => f.write_str("azimuth motor version"),
            Query::DeviceVersion(Device::AltMotor) => f.write_str("altitude motor version"),
            Query::Backlash(d, sense) => write!(
                f,
                "{} backlash, {}",
                match d {
                    Device::AzmMotor => "azimuth",
                    Device::AltMotor => "altitude",
                },
                match sense {
                    Sense::Positive => "positive",
                    Sense::Negative => "negative",
                }
            ),
        }
    }
}

/// `AAAA,BBBB` (or 8 hex digits each): fractions of a revolution.
fn parse_angles(payload: &[u8], digits: usize) -> Option<Value> {
    let text = std::str::from_utf8(payload).ok()?;
    let (a, b) = text.split_once(',')?;
    if a.len() != digits || b.len() != digits {
        return None;
    }
    let full = if digits == 8 { 2f64.powi(32) } else { 65_536.0 };
    let azm = u32::from_str_radix(a, 16).ok()?;
    let alt = u32::from_str_radix(b, 16).ok()?;
    Some(Value::Angles {
        azm_deg: azm as f64 / full * 360.0,
        alt_deg: alt as f64 / full * 360.0,
        raw: [azm, alt],
    })
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Value {
    Echo(u8),
    Version {
        major: u8,
        minor: u8,
    },
    Model(u8),
    Flag(bool),
    TrackingMode(u8),
    Backlash(u8),
    Angles {
        azm_deg: f64,
        alt_deg: f64,
        raw: [u32; 2],
    },
}

impl fmt::Display for Value {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Value::Echo(x) => write!(f, "{:?}", *x as char),
            Value::Version { major, minor } => write!(f, "{major}.{minor}"),
            Value::Model(m) => match model_name(*m) {
                Some(name) => write!(f, "{m} ({name})"),
                None => write!(f, "{m} (unknown)"),
            },
            Value::Flag(b) => f.write_str(if *b { "yes" } else { "no" }),
            Value::TrackingMode(m) => match tracking_name(*m) {
                Some(name) => write!(f, "{m} ({name})"),
                None => write!(f, "{m} (unknown)"),
            },
            Value::Backlash(v) => write!(f, "{v}"),
            Value::Angles {
                azm_deg, alt_deg, ..
            } => write!(f, "azm {azm_deg:.5}°, alt {alt_deg:.5}°"),
        }
    }
}

/// Model codes: 1–12 from the Celestron document; 14, 20 and 22 from libnexstar.
pub fn model_name(code: u8) -> Option<&'static str> {
    Some(match code {
        1 => "NexStar GPS Series",
        3 => "NexStar i-Series",
        4 => "NexStar i-Series SE",
        5 => "CGE",
        6 => "Advanced GT",
        7 => "SLT",
        9 => "CPC",
        10 => "GT",
        11 => "NexStar 4/5 SE",
        12 => "NexStar 6/8 SE",
        14 => "CGEM",
        20 => "Advanced VX",
        22 => "NexStar Evolution",
        _ => return None,
    })
}

pub const EVOLUTION_MODEL: u8 = 22;

pub fn tracking_name(mode: u8) -> Option<&'static str> {
    Some(match mode {
        0 => "off",
        1 => "alt-az",
        2 => "EQ north",
        3 => "EQ south",
        _ => return None,
    })
}

/// What discovery sends, in order: identification and state once, then
/// `repeats` pairs of a position reading and an echo, to measure reply
/// latency through the hand control to the motors and back, and to it alone.
pub fn plan(repeats: usize) -> Vec<Query> {
    let mut queries = vec![
        Query::Echo(b'x'),
        Query::Version,
        Query::Model,
        Query::DeviceVersion(Device::AzmMotor),
        Query::DeviceVersion(Device::AltMotor),
        Query::Backlash(Device::AzmMotor, Sense::Positive),
        Query::Backlash(Device::AzmMotor, Sense::Negative),
        Query::Backlash(Device::AltMotor, Sense::Positive),
        Query::Backlash(Device::AltMotor, Sense::Negative),
        Query::AlignmentComplete,
        Query::GotoInProgress,
        Query::TrackingMode,
        Query::AzmAlt,
    ];
    for i in 0..repeats {
        queries.push(Query::PreciseAzmAlt);
        queries.push(Query::Echo(b'0' + (i % 10) as u8));
    }
    queries
}

/// Documented commands that discovery deliberately never sends, and why.
pub const NOT_SENT: &[(&str, &str)] = &[
    (
        "Slew (fixed or variable rate), GOTO, Cancel GOTO",
        "motion: proposed above for the hardware adapter, not sent",
    ),
    (
        "Sync, Set Tracking Mode, Set Time, Set Location, RTC set",
        "change mount or hand control state",
    ),
    (
        "Get Location (`w`), GPS latitude and longitude",
        "would read the observing site's coordinates (docs/privacy.md)",
    ),
    (
        "Get Time (`h`), GPS and RTC time",
        "not needed; the time zone hints at location",
    ),
    (
        "Get RA/DEC (`E`, `e`)",
        "meaningless before alignment; axis angles (`z`) suffice",
    ),
];

/// Bytes a command may start with. Tests check every catalog query against it.
pub const ALLOWED_FIRST_BYTES: &[u8] = b"KVmJLtZzP";
