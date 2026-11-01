//! A session trace for the field: one JSON object per line, flushed as it
//! is written, so a hang or a power cut leaves everything up to that moment.
//! It records every byte to and from the hand controller (one line per
//! write, per reply up to its `#`, per read that timed out), with the
//! session's requests, state changes, positions and messages, so a fault or
//! a hand controller that stops answering can be worked out afterwards.
//!
//! Nothing in it locates the site: the adapter exchanges versions, modes,
//! backlash and motor counts from power-on, never the hand controller's
//! time or location, and the port name is redacted. The app writes it to
//! its local sessions folder, never to the repo.

use std::{
    fs::{self, File},
    io::{self, BufWriter, Write},
    path::Path,
    sync::{Arc, Mutex},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use cwb_celestron_discovery::Link;
use cwb_mount_core::Nanos;
use serde_json::{Value, json};

use cwb_mount_celestron::adapter::Clock;

/// The trace file, shared by the session and its link.
#[derive(Clone)]
pub struct Trace {
    out: Arc<Mutex<Out>>,
    clock: Clock,
}

struct Out {
    file: Box<dyn Write + Send>,
    /// Set when a write failed: the session carries on without its trace.
    failed: bool,
}

impl Trace {
    /// Creates the file, and its folder if need be.
    pub fn create(path: &Path, clock: Clock) -> io::Result<Self> {
        if let Some(dir) = path.parent() {
            fs::create_dir_all(dir)?;
        }
        Ok(Self::to(
            Box::new(BufWriter::new(File::create(path)?)),
            clock,
        ))
    }

    pub fn to(file: Box<dyn Write + Send>, clock: Clock) -> Self {
        let trace = Self {
            out: Arc::new(Mutex::new(Out {
                file,
                failed: false,
            })),
            clock,
        };
        let unix_ms = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_or(0, |d| d.as_millis() as u64);
        // Lines carry the session clock; this ties it to the wall clock.
        trace.write("trace_start", json!({ "unix_ms": unix_ms }));
        trace
    }

    pub fn write(&self, event: &str, detail: Value) {
        self.write_at((self.clock)(), event, detail);
    }

    pub fn write_at(&self, t_ns: Nanos, event: &str, detail: Value) {
        let mut line = json!({ "t_ns": t_ns, "event": event });
        if let (Value::Object(line), Value::Object(detail)) = (&mut line, detail) {
            line.extend(detail);
        }
        let Ok(mut out) = self.out.lock() else {
            return;
        };
        if out.failed {
            return;
        }
        let result = serde_json::to_writer(&mut out.file, &line)
            .map_err(io::Error::from)
            .and_then(|()| out.file.write_all(b"\n"))
            .and_then(|()| out.file.flush());
        out.failed = result.is_err();
    }
}

fn hex(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|b| format!("{b:02X}"))
        .collect::<Vec<_>>()
        .join(" ")
}

/// A link that copies its traffic to the trace.
pub struct TracingLink<L: Link> {
    inner: L,
    trace: Trace,
    /// Reply bytes not yet written: (time of the first, bytes).
    pending: Option<(Nanos, Vec<u8>)>,
}

impl<L: Link> TracingLink<L> {
    pub fn new(inner: L, trace: Trace) -> Self {
        Self {
            inner,
            trace,
            pending: None,
        }
    }

    fn flush_reply(&mut self) {
        if let Some((t, bytes)) = self.pending.take() {
            let end = (self.trace.clock)();
            self.trace
                .write_at(t, "rx", json!({ "hex": hex(&bytes), "last_ns": end }));
        }
    }
}

impl<L: Link> Link for TracingLink<L> {
    fn write_all(&mut self, bytes: &[u8]) -> io::Result<()> {
        self.flush_reply();
        let result = self.inner.write_all(bytes);
        let mut detail = json!({ "hex": hex(bytes) });
        if let Err(e) = &result {
            detail["error"] = json!(e.to_string());
        }
        self.trace.write("tx", detail);
        result
    }

    fn read_byte(&mut self, timeout: Duration) -> io::Result<Option<u8>> {
        let result = self.inner.read_byte(timeout);
        match &result {
            Ok(Some(b)) => {
                let now = (self.trace.clock)();
                self.pending
                    .get_or_insert_with(|| (now, Vec::new()))
                    .1
                    .push(*b);
                if *b == b'#' {
                    self.flush_reply();
                }
            }
            Ok(None) => {
                self.flush_reply();
                self.trace.write(
                    "rx_timeout",
                    json!({ "waited_ms": timeout.as_millis() as u64 }),
                );
            }
            Err(e) => {
                self.flush_reply();
                self.trace
                    .write("rx_error", json!({ "error": e.to_string() }));
            }
        }
        result
    }

    fn discard_input(&mut self) -> io::Result<()> {
        self.flush_reply();
        self.trace.write("discard_input", json!({}));
        self.inner.discard_input()
    }
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicI64, Ordering};

    use super::*;

    /// A shared buffer the test can read back.
    #[derive(Clone, Default)]
    struct Buffer(Arc<Mutex<Vec<u8>>>);

    impl Write for Buffer {
        fn write(&mut self, b: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(b);
            Ok(b.len())
        }
        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl Buffer {
        fn lines(&self) -> Vec<Value> {
            String::from_utf8(self.0.lock().unwrap().clone())
                .unwrap()
                .lines()
                .map(|l| serde_json::from_str(l).unwrap())
                .collect()
        }
    }

    /// Replies with queued bytes, then times out.
    struct Script(Vec<u8>);

    impl Link for Script {
        fn write_all(&mut self, _: &[u8]) -> io::Result<()> {
            Ok(())
        }
        fn read_byte(&mut self, _: Duration) -> io::Result<Option<u8>> {
            Ok((!self.0.is_empty()).then(|| self.0.remove(0)))
        }
        fn discard_input(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    #[test]
    fn records_writes_whole_replies_and_timeouts() {
        let buffer = Buffer::default();
        let t = Arc::new(AtomicI64::new(0));
        let clock: Clock = {
            let t = t.clone();
            Arc::new(move || t.fetch_add(1_000, Ordering::Relaxed))
        };
        let trace = Trace::to(Box::new(buffer.clone()), clock);
        let mut link = TracingLink::new(Script(vec![b'x', b'#']), trace);
        link.write_all(b"Kx").unwrap();
        for _ in 0..3 {
            link.read_byte(Duration::from_millis(5)).unwrap();
        }
        let events: Vec<_> = buffer
            .lines()
            .iter()
            .map(|l| l["event"].as_str().unwrap().to_owned())
            .collect();
        assert_eq!(events, ["trace_start", "tx", "rx", "rx_timeout"]);
        let lines = buffer.lines();
        assert_eq!(lines[1]["hex"], "4B 78");
        assert_eq!(lines[2]["hex"], "78 23");
        assert_eq!(lines[3]["waited_ms"], 5);
    }
}
