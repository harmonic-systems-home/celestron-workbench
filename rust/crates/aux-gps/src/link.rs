//! The connection to the bus: the Evolution's Wi-Fi module, which bridges
//! a TCP connection on port 2000 to the AUX bus (ADR 0018, "SkySafari over
//! Wi-Fi"), or a fake for tests and `--simulate`.

use std::{
    collections::VecDeque,
    io::{self, Read, Write},
    net::{TcpStream, ToSocketAddrs},
    time::Duration,
};

/// The Wi-Fi module's TCP port.
pub const PORT: u16 = 2000;

pub trait Link {
    fn send(&mut self, bytes: &[u8]) -> io::Result<()>;
    /// Bytes heard within `timeout`; empty if none.
    fn recv(&mut self, timeout: Duration) -> io::Result<Vec<u8>>;
}

pub struct TcpLink {
    stream: TcpStream,
}

impl TcpLink {
    pub fn connect(host: &str) -> io::Result<Self> {
        let addr = (host, PORT)
            .to_socket_addrs()?
            .next()
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "no address for the mount"))?;
        let stream = TcpStream::connect_timeout(&addr, Duration::from_secs(5))?;
        stream.set_nodelay(true)?;
        Ok(TcpLink { stream })
    }
}

impl Link for TcpLink {
    fn send(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.stream.write_all(bytes)
    }

    fn recv(&mut self, timeout: Duration) -> io::Result<Vec<u8>> {
        self.stream
            .set_read_timeout(Some(timeout.max(Duration::from_millis(1))))?;
        let mut buf = [0u8; 512];
        match self.stream.read(&mut buf) {
            Ok(0) => Err(io::Error::new(
                io::ErrorKind::ConnectionAborted,
                "the mount closed the connection",
            )),
            Ok(n) => Ok(buf[..n].to_vec()),
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::TimedOut
                ) =>
            {
                Ok(Vec::new())
            }
            Err(e) => Err(e),
        }
    }
}

/// A bus for tests: hands out queued chunks, one per `recv`, and records
/// everything sent.
#[derive(Default)]
pub struct FakeLink {
    pub incoming: VecDeque<Vec<u8>>,
    pub sent: Vec<Vec<u8>>,
}

impl Link for FakeLink {
    fn send(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.sent.push(bytes.to_vec());
        Ok(())
    }

    fn recv(&mut self, _timeout: Duration) -> io::Result<Vec<u8>> {
        Ok(self.incoming.pop_front().unwrap_or_default())
    }
}
