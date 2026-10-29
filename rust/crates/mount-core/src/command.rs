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
/// direction, a fixed rate, for at most `duration_ms`. There is no goto.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct MoveRequest {
    /// Chosen by the requester; a repeated ID is refused, never re-sent.
    pub request_id: String,
    pub axis: Axis,
    pub direction: Direction,
    pub rate_deg_s: f64,
    pub duration_ms: u64,
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
    },
    Stop {
        axis: Axis,
    },
    StopAll,
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
    pub request: MoveRequest,
    pub stages: Vec<(Stage, Nanos)>,
    /// Why it was refused or how it ended.
    pub reason: Option<String>,
    pub fault: Option<FaultKind>,
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
