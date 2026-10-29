//! A live phone-to-Mac clock model, refitted as clock exchanges arrive
//! (ADR 0001). Only exchanges answered by this Mac clock domain and made
//! in the phone's current boot are used.

use cwb_protocol::ClockResult;
use cwb_storage::clockfit::{self, ClockModel, Exchange};

pub struct LiveClock {
    mac_clock_boot_id: String,
    phone_boot_id: Option<String>,
    exchanges: Vec<Exchange>,
    model: Option<ClockModel>,
}

impl LiveClock {
    pub fn new(mac_clock_boot_id: &str) -> Self {
        Self {
            mac_clock_boot_id: mac_clock_boot_id.to_owned(),
            phone_boot_id: None,
            exchanges: Vec::new(),
            model: None,
        }
    }

    /// The phone's clock domain, from its `hello`. A new one discards the model.
    pub fn phone_boot(&mut self, boot_id: &str) {
        if self.phone_boot_id.as_deref() != Some(boot_id) {
            self.phone_boot_id = Some(boot_id.to_owned());
            self.exchanges.clear();
            self.model = None;
        }
    }

    pub fn add(&mut self, result: &ClockResult) {
        if result.mac_clock_boot_id != self.mac_clock_boot_id
            || self
                .exchanges
                .iter()
                .any(|e| e.index == result.exchange_index)
        {
            return;
        }
        self.exchanges.push(Exchange {
            index: result.exchange_index,
            phone_send_ns: result.phone_send_ns,
            mac_receive_ns: result.mac_receive_ns,
            mac_send_ns: result.mac_send_ns,
            phone_receive_ns: result.phone_receive_ns,
        });
        self.model = clockfit::fit(
            &self.mac_clock_boot_id,
            self.phone_boot_id.as_deref(),
            &self.exchanges,
        );
    }

    pub fn model(&self) -> Option<&ClockModel> {
        self.model.as_ref()
    }
}
