//! Motion requests, the commands sent to an adapter, and command records.

use serde::Serialize;

use crate::FaultKind;

/// Mac monotonic nanoseconds (ADR 0001).
pub type Nanos = i64;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Axis {
    Azimuth,
    Altitude,
}

impl Axis {
    pub const BOTH: [Axis; 2] = [Axis::Azimuth, Axis::Altitude];

    pub fn index(self) -> usize {
        match self {
            Axis::Azimuth => 0,
            Axis::Altitude => 1,
        }
    }

    pub fn other(self) -> Axis {
        match self {
            Axis::Azimuth => Axis::Altitude,
            Axis::Altitude => Axis::Azimuth,
        }
    }
}

/// Positive is the axis's increasing angle (as the IMU observes it).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Direction {
    Positive,
    Negative,
}

impl Direction {
    pub fn sign(self) -> f64 {
        match self {
            Direction::Positive => 1.0,
            Direction::Negative => -1.0,
        }
    }
}

/// What the operator (or a test protocol) asks for: one axis, one
/// direction, a fixed rate, for at most `duration_ms`.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MoveRequest {
    /// Chosen by the requester; a repeated ID is refused, never re-sent.
    pub request_id: String,
    pub axis: Axis,
    pub direction: Direction,
    /// The axis rate. For a fixed-rate move, the nominal speed of that rate,
    /// used by the safety checks and for commanded travel.
    pub rate_deg_s: f64,
    pub duration_ms: u64,
    /// A keypad rate (1–9, `MC_MOVE_POS`/`MC_MOVE_NEG`, as the hand
    /// controller's arrow keys send) instead of a variable rate.
    pub fixed_rate: Option<u8>,
}

/// Axis positions are counted as the motor controllers count them: 24 bits
/// per revolution (one unit is 0.077″), but positive as the IMU sees it.
/// Adapters convert for an axis whose motor counts the other way.
pub const UNITS_PER_REV: i64 = 1 << 24;

pub fn units_to_deg(units: i64) -> f64 {
    units as f64 * 360.0 / UNITS_PER_REV as f64
}

pub fn deg_to_units(deg: f64) -> i64 {
    (deg / 360.0 * UNITS_PER_REV as f64).round() as i64
}

/// A position, wrapped into one revolution.
pub fn wrap_units(units: i64) -> u32 {
    units.rem_euclid(UNITS_PER_REV) as u32
}

/// The signed distance from `from` to `to` the short way round.
pub fn units_between(from: u32, to: u32) -> i64 {
    let d = (i64::from(to) - i64::from(from)).rem_euclid(UNITS_PER_REV);
    if d > UNITS_PER_REV / 2 {
        d - UNITS_PER_REV
    } else {
        d
    }
}

/// The motor controllers' two gotos (ADR 0014). Their speeds are measured,
/// not documented.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum GotoSpeed {
    Slow,
    Fast,
}

/// A goto by the axis's own position, relative to where it is now
/// (ADR 0014). With `approach`, the axis always ends moving that way: a
/// goto heading the other way first goes `approach_margin_deg` past the
/// target, then comes back slowly. Off by default: anti-backlash, once set,
/// does the same job in the motor controllers.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct GotoRequest {
    /// Chosen by the requester; a repeated ID is refused, never re-sent.
    pub request_id: String,
    pub axis: Axis,
    /// Signed, as the IMU sees the axis.
    pub delta_deg: f64,
    pub speed: GotoSpeed,
    /// The direction the axis must be moving as it arrives.
    pub approach: Option<Direction>,
}

/// Either kind of request, as kept in its record.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Request {
    Move(MoveRequest),
    Goto(GotoRequest),
}

impl Request {
    pub fn axis(&self) -> Axis {
        match self {
            Request::Move(m) => m.axis,
            Request::Goto(g) => g.axis,
        }
    }
}

pub type CommandId = u64;

/// What an adapter is told to do. Every motion command ends with a stop
/// from the controller; the adapter never decides to keep moving.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MountCommand {
    Move {
        id: CommandId,
        axis: Axis,
        direction: Direction,
        rate_deg_s: f64,
        /// Sent as this keypad rate (1–9) rather than as `rate_deg_s`.
        fixed_rate: Option<u8>,
    },
    /// Go to `target` (axis units, see [`UNITS_PER_REV`]) and hold there.
    /// One request's legs share its ID.
    Goto {
        id: CommandId,
        axis: Axis,
        target: u32,
        speed: GotoSpeed,
    },
    Stop {
        axis: Axis,
    },
    StopAll,
}

impl MountCommand {
    pub fn is_stop(&self) -> bool {
        matches!(self, MountCommand::Stop { .. } | MountCommand::StopAll)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Stage {
    Requested,
    Transmitted,
    Acknowledged,
    StopSent,
    Completed,
    Cancelled,
    TimedOut,
    Rejected,
    Unknown,
}

impl Stage {
    pub fn is_final(self) -> bool {
        matches!(
            self,
            Stage::Completed
                | Stage::Cancelled
                | Stage::TimedOut
                | Stage::Rejected
                | Stage::Unknown
        )
    }
}

/// The life of one request, recorded before anything is transmitted
/// (ADR 0005). Every record ends in a final stage; none stays active.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct CommandRecord {
    /// `None` for requests refused before a command was created.
    pub command_id: Option<CommandId>,
    pub request: Request,
    pub stages: Vec<(Stage, Nanos)>,
    /// Why it was refused or how it ended.
    pub reason: Option<String>,
    pub fault: Option<FaultKind>,
    /// Signed travel on the commanded axis: rate × time from transmission
    /// to stop, and the IMU's integrated rate over the same command. Set
    /// when the command completes.
    pub commanded_deg: Option<f64>,
    pub observed_deg: Option<f64>,
    /// For a goto that was sent: what the axis's own positions showed.
    pub goto: Option<GotoOutcome>,
}

/// How a goto went, from the axis positions read while it ran (ADR 0014).
/// Positions are axis units; "past" is beyond the final target in the
/// direction of the last leg.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct GotoOutcome {
    pub start: u32,
    pub target: u32,
    /// Leg targets in order; two when the approach flag added a leg.
    pub legs: Vec<u32>,
    /// The position last read before a stop was sent, if one was: with
    /// `last`, it shows whether the stop ended the goto.
    pub at_stop: Option<u32>,
    /// The last position read.
    pub last: Option<u32>,
    /// `last` minus `target`, signed.
    pub error_units: Option<i64>,
    /// The furthest any reading went past the target on the last leg (0 if
    /// none did).
    pub overshoot_units: i64,
    /// How many times readings crossed the target on the last leg.
    pub crossings: u32,
    /// From the last leg leaving to the axis settling, if it settled.
    pub settle_ms: Option<f64>,
}

impl CommandRecord {
    pub fn last_stage(&self) -> Stage {
        self.stages.last().map_or(Stage::Requested, |s| s.0)
    }

    pub fn has(&self, stage: Stage) -> bool {
        self.stages.iter().any(|s| s.0 == stage)
    }
}

/// One IMU observation, already turned into mount-axis terms: rates about
/// the azimuth and altitude axes and the tube's altitude, at `t_ns` on the
/// Mac clock (aligned through the clock model).
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Observation {
    pub t_ns: Nanos,
    /// Indexed by [`Axis::index`].
    pub rate_deg_s: [f64; 2],
    pub altitude_deg: f64,
}
