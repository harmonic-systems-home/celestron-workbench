//! Bonjour advertisement of the receiver (`_cwb-imu._tcp`, ADR 0004).
//!
//! Uses macOS's own `dns-sd` tool, which registers the service with the
//! system mDNSResponder for as long as it runs. That avoids a second mDNS
//! stack in this process and needs no unsafe FFI.

use tokio::process::{Child, Command};

pub const SERVICE_TYPE: &str = "_cwb-imu._tcp";

/// Keeps the service registered until dropped.
pub struct Advertisement {
    _child: Child,
}

impl Advertisement {
    pub fn start(name: &str, port: u16) -> std::io::Result<Self> {
        let child = Command::new("dns-sd")
            .args(["-R", name, SERVICE_TYPE, "local", &port.to_string()])
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .spawn()?;
        Ok(Self { _child: child })
    }
}
