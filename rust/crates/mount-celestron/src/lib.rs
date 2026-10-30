//! The Celestron motion adapter (plan Prompt 8, ADR 0013): the only code in
//! this project that can move real hardware (ADR 0005, hardware gate).
//!
//! It carries out the [`cwb_mount_core::Controller`]'s commands through the
//! hand controller's serial port, using only the commands the approved
//! discovery report proposed: variable-rate slews and stops on one axis
//! ([`encode`]). It never starts, extends or repeats motion on its own, and
//! it stops both axes when it is dropped.
//!
//! [`fake`] is a simulated hand controller over the simulated mount, so the
//! adapter and the runner can be exercised without hardware.

pub mod adapter;
pub mod encode;
pub mod fake;
pub mod prepare;
pub mod stoptest;

pub use adapter::{CelestronAdapter, Position, Transaction};
pub use encode::CelestronSettings;
