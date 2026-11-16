//! Tests whether a hand controller takes its time and location from GPS
//! replies on the AUX bus (ADR 0020).
//!
//! It speaks as the GPS (0xB0) through the Evolution's Wi-Fi module: it
//! pushes the replies a GPS gives when asked for its fix, time and position,
//! and answers any GPS request it hears. Everything it can send is built by
//! [`gps::Fix::packet`]: source 0xB0, a hand controller as destination, and
//! one of the GPS message IDs. Nothing here can address a motor, so nothing
//! can move the mount.
//!
//! The location is always the decoy in [`gps::DECOY`], never the observing
//! site, so a trace or the bus never carries the real one.

pub mod gps;
pub mod link;
pub mod packet;
pub mod run;
