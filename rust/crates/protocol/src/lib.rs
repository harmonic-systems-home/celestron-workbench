//! Phone–Mac wire protocol, version 1.
//!
//! The JSON Schema in `schemas/protocol/v1.schema.json` is the contract; the
//! types here mirror it and are tested against the shared examples in
//! `schemas/protocol/examples/`. Units and frames follow ADR 0002, timestamps
//! ADR 0001, and framing ADR 0004.

pub mod framing;
pub mod message;
pub mod schema;

pub use message::*;

/// The protocol version this crate speaks.
pub const PROTOCOL_VERSION: u32 = 1;

/// Standard gravity used by the phone to convert Core Motion's g to m/s² (ADR 0002).
pub const STANDARD_GRAVITY_M_S2: f64 = 9.80665;
