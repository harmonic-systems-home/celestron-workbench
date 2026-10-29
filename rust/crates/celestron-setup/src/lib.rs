//! Sets a Celestron hand controller's time and location (ADR 0011), so it
//! can orient on the sky without keypad entry.
//!
//! These are the first commands that change the hand controller, so they
//! live apart from read-only discovery. The only sendable commands are
//! Set Time (`H`), Set Location (`W`), the motor controllers' anti-backlash
//! set and get ([`backlash`]), and their read-backs (`h`, `w`): nothing here
//! can move the mount. Site coordinates come from a git-ignored
//! site file ([`site`]) and are never printed, logged or shown in `Debug`.

pub mod apply;
pub mod backlash;
pub mod command;
pub mod fake;
pub mod site;

pub use apply::{Applied, ReadBack, set_location, set_time};
pub use command::{Dms, HandTime, Location};
pub use site::Site;

use thiserror::Error;

#[derive(Debug, Error, PartialEq)]
pub enum SetupError {
    #[error("site file: {0}")]
    Site(String),
    #[error("time: {0}")]
    Time(String),
}
