//! Bench analysis (plan Prompt 5): deterministic metrics and reports from a
//! stored session. Recorded and simulated sessions go through the same path:
//! load from the database, analyze, render.

pub mod config;
pub mod data;
pub mod math;
pub mod report;
pub mod stationary;
pub mod synthetic;

pub use config::Config;
pub use data::{SessionData, load};
pub use stationary::{Analysis, analyze};

use thiserror::Error;

#[derive(Debug, Error)]
pub enum AnalysisError {
    #[error(transparent)]
    Storage(#[from] cwb_storage::StorageError),
    #[error(transparent)]
    Sqlite(#[from] rusqlite::Error),
    #[error("config: {0}")]
    Config(String),
    #[error("session {0} has no phone device to analyse")]
    NoDevice(String),
    #[error("session {0} has several devices; choose one")]
    SeveralDevices(String),
}

pub(crate) fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
