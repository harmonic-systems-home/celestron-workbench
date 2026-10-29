//! The run log: one JSON object per line, on the Mac clock. It records the
//! configuration, the checklist confirmation, every operator line, request,
//! command sent, mount report and position, state change, fault, alert and
//! finished command (plan Prompt 8). Logs go to the git-ignored `reports/`.

use std::io::Write;

use cwb_mount_core::Nanos;
use serde_json::{Value, json};

pub struct RunLog {
    out: Box<dyn Write + Send>,
    /// Set when a write failed; the runner surfaces it but keeps running,
    /// because stopping the mount matters more than the log.
    pub failed: Option<String>,
}

impl RunLog {
    pub fn new(out: Box<dyn Write + Send>) -> Self {
        Self { out, failed: None }
    }

    pub fn discard() -> Self {
        Self::new(Box::new(std::io::sink()))
    }

    pub fn write(&mut self, t_ns: Nanos, event: &str, detail: Value) {
        let mut line = json!({ "t_ns": t_ns, "event": event });
        if let (Value::Object(line), Value::Object(detail)) = (&mut line, detail) {
            line.extend(detail);
        }
        let result = serde_json::to_writer(&mut self.out, &line)
            .map_err(std::io::Error::from)
            .and_then(|()| self.out.write_all(b"\n"))
            .and_then(|()| self.out.flush());
        if let Err(e) = result
            && self.failed.is_none()
        {
            self.failed = Some(e.to_string());
        }
    }
}
