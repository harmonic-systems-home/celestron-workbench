//! Read-only discovery for a Celestron mount through its hand controller's
//! serial port (plan Prompt 7, ADR 0010).
//!
//! It lists candidate serial ports, sends only documented non-motion
//! queries ([`query`]), records every exchange byte for byte, and writes a
//! protocol compatibility report that maps each command proposed for the
//! hardware adapter to Celestron's documentation or marks it for hardware
//! observation ([`proposed`]). Nothing here can move a mount: the only
//! sendable type is [`query::Query`], and it has no motion variant.

pub mod discover;
pub mod fake;
pub mod link;
pub mod proposed;
pub mod query;
pub mod report;

pub use discover::{Discovery, HandController, discover, summarize};
pub use link::{Link, Outcome, SerialLink, list_ports, redact_path, transact};
pub use query::Query;
