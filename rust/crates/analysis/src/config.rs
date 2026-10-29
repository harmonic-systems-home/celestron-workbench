//! Versioned analysis configuration (`analysis/*.toml`).

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::AnalysisError;

/// The only config format version this software reads.
pub const CONFIG_VERSION: u32 = 1;

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Config {
    pub version: u32,
    pub name: String,
    #[serde(default)]
    pub description: String,
    pub exclusions: Exclusions,
    pub still: Still,
    pub resolution: Resolution,
    pub acceptance: Acceptance,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Exclusions {
    /// Leading seconds treated as warm-up: reported, never used for steady state.
    pub warm_up_s: f64,
}

/// Still-window detection: the fused rotation rate's magnitude, averaged
/// over `smoothing_s`, stays below `max_rate_deg_s` for at least
/// `min_duration_s`. Each window is trimmed by `trim_s` at both ends.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Still {
    pub smoothing_s: f64,
    pub max_rate_deg_s: f64,
    pub min_duration_s: f64,
    pub trim_s: f64,
    /// A gap in phone timestamps longer than this many nominal intervals
    /// splits a window.
    pub max_gap_intervals: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Resolution {
    /// Averaging times (s) to tabulate; those longer than a third of the
    /// longest steady-state window are skipped.
    pub tau_s: Vec<f64>,
    /// Shortest averaging time considered when searching for the best
    /// resolution. Core Motion's fused outputs are filtered, so their
    /// sample-to-sample noise is tiny and says nothing about settle windows.
    pub min_window_s: f64,
    /// Coverage factor for the smallest resolvable step (2 ≈ 95 %).
    pub coverage_k: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Acceptance {
    /// Delivered rate may fall short of the requested rate by this fraction.
    pub max_rate_shortfall: f64,
    pub max_missing_samples: u64,
    /// Clock-model uncertainty limit (ms); sessions without exchanges are reported, not failed.
    pub max_clock_uncertainty_ms: f64,
    pub min_steady_state_s: f64,
}

impl Config {
    pub fn parse(text: &str) -> Result<Self, AnalysisError> {
        let config: Self =
            toml::from_str(text).map_err(|e| AnalysisError::Config(e.to_string()))?;
        if config.version != CONFIG_VERSION {
            return Err(AnalysisError::Config(format!(
                "config version {} is not supported (expected {CONFIG_VERSION})",
                config.version
            )));
        }
        Ok(config)
    }

    /// The default stationary config, as committed in `analysis/stationary.toml`.
    pub fn stationary() -> Self {
        Self::parse(STATIONARY).expect("the committed stationary config parses")
    }
}

pub const STATIONARY: &str = include_str!("../../../../analysis/stationary.toml");

/// SHA-256 of a config file's bytes, recorded in every report.
pub fn sha256(text: &str) -> String {
    crate::hex(&Sha256::digest(text.as_bytes()))
}
