//! Mount safety core (ADR 0005, plan Prompt 6): the session state machine,
//! the safety configuration, command records, and the interlock
//! [`Controller`].
//!
//! This crate is deliberately free of I/O. It decides what may happen and
//! returns the commands to send; adapters (the simulator now, the Celestron
//! adapter after the hardware gate) carry them out through [`MountAdapter`].
//!
//! ```text
//! DISCONNECTED → CONNECTED_READ_ONLY → ARMED → MOVING → STOPPING → ARMED
//!                      any state with a fault → FAULT_LATCHED
//!                      FAULT_LATCHED → CONNECTED_READ_ONLY   (manual reset only)
//! ```

pub mod command;
pub mod config;
pub mod controller;
pub mod imu;
pub mod state;

pub use command::{
    Axis, CommandId, CommandRecord, Direction, GotoOutcome, GotoRequest, GotoSpeed, MountCommand,
    MoveRequest, Nanos, Observation, Request, Stage, UNITS_PER_REV, deg_to_units, units_between,
    units_to_deg, wrap_units,
};
pub use config::SafetyConfig;
pub use controller::{Action, Controller, FaultRecord, Refused};
pub use state::{FaultKind, InvalidTransition, MountEvent, MountState, transition};

/// What the mount reports back.
#[derive(Debug, Clone, PartialEq)]
pub enum MountReport {
    /// A move command left for the mount at `sent_ns`, which can be later
    /// than when it was handed over: a serial adapter may be mid-way through
    /// a position read (ADR 0013).
    Sent {
        id: CommandId,
        sent_ns: Nanos,
    },
    Acknowledged(CommandId),
    /// While a goto runs, and after a stop until the axis reports it done:
    /// the axis's own position (axis units, positive as the IMU sees it),
    /// read at `t_ns`.
    Position {
        axis: Axis,
        t_ns: Nanos,
        units: u32,
    },
    /// The axis's goto-finished flag, read at `t_ns`.
    SlewDone {
        axis: Axis,
        t_ns: Nanos,
        done: bool,
    },
    /// The link to the mount is gone.
    TransportLost,
}

/// What a mount's controller reports about itself.
#[derive(Debug, Clone, Default, PartialEq, serde::Serialize)]
pub struct MountIdentity {
    pub controller_version: Option<String>,
    pub model: Option<String>,
    /// Motor controller firmware, indexed by [`Axis::index`].
    pub motor_versions: [Option<String>; 2],
}

/// Read-only queries. Nothing here can move a mount: read-only discovery
/// (plan Prompt 7) uses only this, before any motion adapter exists.
pub trait MountQueries {
    fn identify(&mut self) -> Result<MountIdentity, TransportError>;
    /// The mount's own axis angles in degrees, indexed by [`Axis::index`].
    /// Before alignment they are relative to where the mount was powered on.
    fn axis_positions_deg(&mut self) -> Result<[f64; 2], TransportError>;
}

/// The boundary every mount implementation sits behind. Implementations do
/// only what they are told: they never start, extend or repeat motion.
pub trait MountAdapter {
    /// Transmits a command. An error means the link is gone.
    fn send(&mut self, command: &MountCommand, now: Nanos) -> Result<(), TransportError>;
    /// Reports that have arrived by `now`.
    fn poll(&mut self, now: Nanos) -> Vec<MountReport>;
}

#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
#[error("mount transport: {0}")]
pub struct TransportError(pub String);
