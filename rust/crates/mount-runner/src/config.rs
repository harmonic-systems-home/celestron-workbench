//! The runner's configuration, from `config/mount.toml` (committed: nothing
//! in it is private). The safety section is the session's safety
//! configuration (ADR 0005); the operator approves it before a session.

use cwb_mount_celestron::AxisSigns;
use cwb_mount_core::SafetyConfig;
use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RunnerConfig {
    pub phone: PhoneConfig,
    pub celestron: AxisSigns,
    pub moves: MoveDefaults,
    pub safety: SafetyConfig,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct PhoneConfig {
    /// The phone body axis toward the tube's sky end: "+y" when the top of
    /// the phone points that way.
    pub tube_axis: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MoveDefaults {
    /// Used when a move command gives no rate or duration.
    pub rate_deg_s: f64,
    pub seconds: f64,
}

impl RunnerConfig {
    pub fn parse(text: &str) -> Result<Self, String> {
        let config: Self = toml::from_str(text).map_err(|e| e.to_string())?;
        config.tube()?;
        let problems = config.safety.problems();
        if !problems.is_empty() {
            return Err(format!("safety: {}", problems.join("; ")));
        }
        Ok(config)
    }

    pub fn tube(&self) -> Result<[f64; 3], String> {
        Ok(match self.phone.tube_axis.as_str() {
            "+x" => [1.0, 0.0, 0.0],
            "-x" => [-1.0, 0.0, 0.0],
            "+y" => [0.0, 1.0, 0.0],
            "-y" => [0.0, -1.0, 0.0],
            "+z" => [0.0, 0.0, 1.0],
            "-z" => [0.0, 0.0, -1.0],
            other => {
                return Err(format!(
                    "phone.tube_axis {other:?}: use +x, -x, +y, -y, +z or -z"
                ));
            }
        })
    }
}
