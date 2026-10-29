//! The observing site, from a git-ignored TOML file (`config/site.local.toml`
//! by default; template in `config/site.example.toml`). Coordinates are
//! private (docs/privacy.md): `Debug` hides them and nothing here prints them.

use std::fmt;

use serde::Deserialize;

use crate::SetupError;

#[derive(Clone, PartialEq, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Site {
    /// A label for the operator; not sent.
    pub name: Option<String>,
    /// Degrees, north positive.
    pub latitude: f64,
    /// Degrees, east positive (west is negative).
    pub longitude: f64,
    /// IANA time zone name, e.g. "America/Denver". Default: this Mac's zone.
    pub time_zone: Option<String>,
}

impl Site {
    pub fn parse(text: &str) -> Result<Self, SetupError> {
        // The TOML error can quote the offending line, which may hold a
        // coordinate, so only its position is kept.
        let site: Site = toml::from_str(text).map_err(|e| {
            SetupError::Site(match e.span() {
                Some(span) => format!(
                    "not valid (problem at line {})",
                    text[..span.start].lines().count().max(1)
                ),
                None => "not valid".into(),
            })
        })?;
        site.check()?;
        Ok(site)
    }

    fn check(&self) -> Result<(), SetupError> {
        if !self.latitude.is_finite() || self.latitude.abs() > 90.0 {
            return Err(SetupError::Site("latitude must be within ±90°".into()));
        }
        if !self.longitude.is_finite() || self.longitude.abs() > 180.0 {
            return Err(SetupError::Site("longitude must be within ±180°".into()));
        }
        if self.latitude == 0.0 && self.longitude == 0.0 {
            return Err(SetupError::Site(
                "latitude and longitude are both 0: fill in the template's placeholders".into(),
            ));
        }
        Ok(())
    }

    /// Hemispheres only, for confirmation prompts.
    pub fn hemispheres(&self) -> &'static str {
        match (self.latitude < 0.0, self.longitude < 0.0) {
            (false, false) => "north, east",
            (false, true) => "north, west",
            (true, false) => "south, east",
            (true, true) => "south, west",
        }
    }
}

impl fmt::Debug for Site {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("Site")
            .field("name", &self.name)
            .field("latitude", &"<private>")
            .field("longitude", &"<private>")
            .field("time_zone", &self.time_zone)
            .finish()
    }
}
