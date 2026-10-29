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
pub mod state;

pub use command::{
    Axis, CommandId, CommandRecord, Direction, MountCommand, MoveRequest, Nanos, Observation, Stage,
};
pub use config::SafetyConfig;
pub use controller::{Action, Controller, FaultRecord, Refused};
pub use state::{FaultKind, InvalidTransition, MountEvent, MountState, transition};

/// What the mount reports back.
#[derive(Debug, Clone, PartialEq)]
pub enum MountReport {
    Acknowledged(CommandId),
    /// The link to the mount is gone.
    TransportLost,
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
