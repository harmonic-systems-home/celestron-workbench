//! The Mac clock domain (ADR 0001).

use std::time::{Instant, SystemTime};

use cwb_protocol::Nanos;

/// Mac monotonic time for one process run: nanoseconds since an `Instant`
/// taken when the clock was created. `boot_id` names the domain, so values
/// from different runs are never compared.
#[derive(Debug)]
pub struct MacClock {
    anchor: Instant,
    boot_id: String,
}

impl MacClock {
    pub fn new() -> Self {
        Self {
            anchor: Instant::now(),
            boot_id: uuid::Uuid::new_v4().to_string(),
        }
    }

    pub fn now_ns(&self) -> Nanos {
        Nanos::try_from(self.anchor.elapsed().as_nanos()).unwrap_or(Nanos::MAX)
    }

    pub fn boot_id(&self) -> &str {
        &self.boot_id
    }
}

impl Default for MacClock {
    fn default() -> Self {
        Self::new()
    }
}

/// Wall-clock UTC as RFC 3339, for humans only (ADR 0001).
pub fn utc_now() -> String {
    time::OffsetDateTime::from(SystemTime::now())
        .format(&time::format_description::well_known::Rfc3339)
        .expect("RFC 3339 formatting of the current time")
}
