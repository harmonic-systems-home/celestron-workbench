//! Byte links to a hand controller: a serial port, or the simulated hand
//! controller in [`crate::fake`]. Port listings never carry USB serial
//! numbers, and [`redact_path`] removes them from device paths.

use std::{
    io,
    time::{Duration, Instant},
};

use serde::Serialize;

use crate::query::REPLY_TIMEOUT_MS;

pub trait Link {
    fn write_all(&mut self, bytes: &[u8]) -> io::Result<()>;
    /// One byte, or `None` if nothing arrives within `timeout`.
    fn read_byte(&mut self, timeout: Duration) -> io::Result<Option<u8>>;
    /// Drops anything left from an earlier exchange.
    fn discard_input(&mut self) -> io::Result<()>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum Outcome {
    Ok,
    /// Pass-through reply with the extra byte: the device didn't answer.
    DeviceNoResponse,
    Timeout,
    /// A terminated reply of the wrong length or content.
    Malformed,
    LinkError,
}

/// Sends one command and reads exactly `reply_len` payload bytes, then the
/// `#` terminator. A pass-through reply with one extra byte before `#` means
/// the device didn't answer (the protocol's own error flag).
pub fn transact(
    link: &mut impl Link,
    sent: &[u8],
    reply_len: usize,
    pass_through: bool,
) -> (Outcome, Vec<u8>) {
    let deadline = Instant::now() + Duration::from_millis(REPLY_TIMEOUT_MS);
    if link
        .discard_input()
        .and_then(|()| link.write_all(sent))
        .is_err()
    {
        return (Outcome::LinkError, Vec::new());
    }
    let n = reply_len;
    let mut got = Vec::new();
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let byte = match link.read_byte(remaining) {
            Ok(Some(b)) => b,
            Ok(None) => return (Outcome::Timeout, got),
            Err(_) => return (Outcome::LinkError, got),
        };
        got.push(byte);
        if got.len() <= n {
            continue;
        }
        if byte == b'#' {
            let outcome = if got.len() == n + 1 {
                Outcome::Ok
            } else if pass_through && got.len() == n + 2 {
                Outcome::DeviceNoResponse
            } else {
                Outcome::Malformed
            };
            return (outcome, got);
        }
        if got.len() > n + 16 {
            return (Outcome::Malformed, got);
        }
    }
}

/// The hand control's RS-232 settings: 9600 baud, 8 data bits, no parity, one stop bit.
pub const BAUD: u32 = 9_600;

pub struct SerialLink {
    port: Box<dyn serialport::SerialPort>,
}

impl SerialLink {
    pub fn open(path: &str) -> io::Result<Self> {
        let port = serialport::new(path, BAUD)
            .data_bits(serialport::DataBits::Eight)
            .parity(serialport::Parity::None)
            .stop_bits(serialport::StopBits::One)
            .flow_control(serialport::FlowControl::None)
            .timeout(Duration::from_millis(100))
            .open()
            .map_err(|e| {
                // After the hand controller restarts (a mount power cycle),
                // macOS keeps a device that can't be opened.
                io::Error::new(
                    io::Error::from(e.clone()).kind(),
                    format!(
                        "{e}. If the mount or hand controller was just power-cycled, unplug the USB cable at the hand controller, wait 5 s, and plug it back in"
                    ),
                )
            })?;
        Ok(Self { port })
    }
}

impl Link for SerialLink {
    fn write_all(&mut self, bytes: &[u8]) -> io::Result<()> {
        io::Write::write_all(&mut self.port, bytes)?;
        io::Write::flush(&mut self.port)
    }

    fn read_byte(&mut self, timeout: Duration) -> io::Result<Option<u8>> {
        self.port
            .set_timeout(timeout.max(Duration::from_millis(1)))
            .map_err(io::Error::from)?;
        let mut byte = [0u8; 1];
        match io::Read::read(&mut self.port, &mut byte) {
            Ok(1) => Ok(Some(byte[0])),
            Ok(_) => Ok(None),
            Err(e) if e.kind() == io::ErrorKind::TimedOut => Ok(None),
            Err(e) => Err(e),
        }
    }

    fn discard_input(&mut self) -> io::Result<()> {
        self.port
            .clear(serialport::ClearBuffer::Input)
            .map_err(io::Error::from)
    }
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct PortInfo {
    pub path: String,
    pub usb: Option<UsbInfo>,
}

/// USB identity without the serial number, which is private (docs/privacy.md).
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct UsbInfo {
    pub vid: u16,
    pub pid: u16,
    pub manufacturer: Option<String>,
    pub product: Option<String>,
}

impl UsbInfo {
    pub fn describe(&self) -> String {
        let mut s = format!("USB {:04x}:{:04x}", self.vid, self.pid);
        for part in [&self.manufacturer, &self.product].into_iter().flatten() {
            s.push_str(", ");
            s.push_str(part);
        }
        s
    }
}

/// Serial ports, USB ones first. On macOS only the `/dev/cu.*` call-out
/// devices are listed: opening `/dev/tty.*` waits for carrier detect.
pub fn list_ports() -> io::Result<Vec<PortInfo>> {
    let mut ports: Vec<PortInfo> = serialport::available_ports()
        .map_err(io::Error::from)?
        .into_iter()
        .filter(|p| !cfg!(target_os = "macos") || p.port_name.starts_with("/dev/cu."))
        .map(|p| PortInfo {
            path: p.port_name,
            usb: match p.port_type {
                serialport::SerialPortType::UsbPort(u) => Some(UsbInfo {
                    vid: u.vid,
                    pid: u.pid,
                    manufacturer: u.manufacturer,
                    product: u.product,
                }),
                _ => None,
            },
        })
        .collect();
    ports.sort_by_key(|p| (p.usb.is_none(), p.path.clone()));
    Ok(ports)
}

/// USB serial device names embed the adapter's serial number or location
/// (`/dev/cu.usbserial-A10KZ3VB`); keep only the driver prefix.
pub fn redact_path(path: &str) -> String {
    for prefix in ["usbserial-", "usbmodem", "SLAB_USBtoUART", "wchusbserial"] {
        if let Some(at) = path.find(prefix) {
            let end = at + prefix.len();
            return if end < path.len() {
                format!("{}<redacted>", &path[..end])
            } else {
                path.to_owned()
            };
        }
    }
    path.to_owned()
}
