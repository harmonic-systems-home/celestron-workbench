//! The Mac side of the phone link (plan Prompt 3): a TCP receiver that stores
//! sessions through one database writer, Bonjour advertisement, and a
//! synthetic phone client for replay and tests. Nothing here can move a mount.

pub mod advertise;
pub mod client;
pub mod server;
pub mod writer;

pub use server::{DEFAULT_PORT, Server};
