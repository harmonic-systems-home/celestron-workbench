//! Set Time (`H`) and Set Location (`W`), and their read-backs (`h`, `w`),
//! as documented in Celestron's NexStar Communication Protocol ("Time/Location
//! Commands", hand control 2.3+). The byte layouts match libnexstar's
//! `tc_set_time` and `tc_set_location`.

use std::fmt;

use jiff::{Timestamp, civil::DateTime, tz::TimeZone};

use crate::{SetupError, site::Site};

/// Set Time: local time, then the standard (non-DST) offset from UTC in
/// whole hours and a daylight saving flag. Local time includes DST.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HandTime {
    pub hour: u8,
    pub minute: u8,
    pub second: u8,
    pub month: u8,
    pub day: u8,
    /// Year − 2000.
    pub year: u8,
    pub standard_offset_hours: i8,
    pub dst: bool,
}

impl HandTime {
    /// `ts` in `tz`. Zones whose standard offset isn't a whole number of
    /// hours, or whose daylight saving isn't one hour, can't be expressed.
    pub fn at(ts: Timestamp, tz: &TimeZone) -> Result<Self, SetupError> {
        let info = tz.to_offset_info(ts);
        let dst = info.dst().is_dst();
        let offset = info.offset().seconds();
        let standard = offset - if dst { 3600 } else { 0 };
        if standard % 3600 != 0 {
            return Err(SetupError::Time(format!(
                "UTC offset {offset} s isn't whole hours (with one-hour daylight saving); the hand controller can't express it"
            )));
        }
        Self::from_parts(info.offset().to_datetime(ts), standard / 3600, dst)
    }

    pub fn from_parts(local: DateTime, standard_hours: i32, dst: bool) -> Result<Self, SetupError> {
        let year = local.year() - 2000;
        if !(0..=255).contains(&year) {
            return Err(SetupError::Time(format!(
                "year {} is out of range",
                local.year()
            )));
        }
        if !(-12..=14).contains(&standard_hours) {
            return Err(SetupError::Time(format!(
                "UTC offset {standard_hours} h is out of range"
            )));
        }
        let b = |v: i8| v as u8;
        Ok(Self {
            hour: b(local.hour()),
            minute: b(local.minute()),
            second: b(local.second()),
            month: b(local.month()),
            day: b(local.day()),
            year: year as u8,
            standard_offset_hours: standard_hours as i8,
            dst,
        })
    }

    /// The 8 bytes after `H`, and the 8 bytes `h` returns.
    pub fn payload(&self) -> [u8; 8] {
        [
            self.hour,
            self.minute,
            self.second,
            self.month,
            self.day,
            self.year,
            // Negative offsets as 256 + offset.
            self.standard_offset_hours as u8,
            u8::from(self.dst),
        ]
    }

    pub fn bytes(&self) -> Vec<u8> {
        [&[SET_TIME][..], &self.payload()].concat()
    }

    pub fn decode(p: &[u8]) -> Option<Self> {
        let [hour, minute, second, month, day, year, tz, dst]: [u8; 8] = p.try_into().ok()?;
        (hour < 24
            && minute < 60
            && second < 61
            && (1..=12).contains(&month)
            && (1..=31).contains(&day)
            && dst <= 1)
            .then_some(Self {
                hour,
                minute,
                second,
                month,
                day,
                year,
                standard_offset_hours: tz as i8,
                dst: dst == 1,
            })
    }

    /// The instant this local time denotes.
    pub fn timestamp(&self) -> Option<Timestamp> {
        let local = DateTime::new(
            2000 + i16::from(self.year),
            self.month as i8,
            self.day as i8,
            self.hour as i8,
            self.minute as i8,
            self.second.min(59) as i8,
            0,
        )
        .ok()?;
        let hours = i32::from(self.standard_offset_hours) + i32::from(self.dst);
        let offset = jiff::tz::Offset::from_hours(hours as i8).ok()?;
        offset.to_timestamp(local).ok()
    }
}

impl fmt::Display for HandTime {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "20{:02}-{:02}-{:02} {:02}:{:02}:{:02}, UTC{:+} standard, daylight saving {}",
            self.year,
            self.month,
            self.day,
            self.hour,
            self.minute,
            self.second,
            self.standard_offset_hours,
            if self.dst { "on" } else { "off" }
        )
    }
}

/// Whole degrees, minutes and seconds, as the hand controller stores them.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Dms {
    pub degrees: u8,
    pub minutes: u8,
    pub seconds: u8,
    /// South or west.
    pub negative: bool,
}

impl Dms {
    /// Rounded to the nearest arcsecond (about 30 m).
    pub fn from_degrees(x: f64) -> Self {
        let total = (x.abs() * 3600.0).round() as u32;
        Self {
            degrees: (total / 3600) as u8,
            minutes: (total / 60 % 60) as u8,
            seconds: (total % 60) as u8,
            negative: x < 0.0 && total > 0,
        }
    }
}

/// Set Location. Coordinates are private: `Debug` hides them.
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Location {
    pub latitude: Dms,
    pub longitude: Dms,
}

impl Location {
    pub fn of(site: &Site) -> Self {
        Self {
            latitude: Dms::from_degrees(site.latitude),
            longitude: Dms::from_degrees(site.longitude),
        }
    }

    /// The 8 bytes after `W`, and the 8 bytes `w` returns.
    pub fn payload(&self) -> [u8; 8] {
        let [a, b] = [self.latitude, self.longitude];
        [
            a.degrees,
            a.minutes,
            a.seconds,
            u8::from(a.negative),
            b.degrees,
            b.minutes,
            b.seconds,
            u8::from(b.negative),
        ]
    }

    pub fn bytes(&self) -> Vec<u8> {
        [&[SET_LOCATION][..], &self.payload()].concat()
    }
}

impl fmt::Debug for Location {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str("Location(<private>)")
    }
}

pub const SET_TIME: u8 = b'H';
pub const SET_LOCATION: u8 = b'W';
pub const GET_TIME: u8 = b'h';
pub const GET_LOCATION: u8 = b'w';
/// Every first byte this crate can send.
pub const ALLOWED_FIRST_BYTES: &[u8] = &[SET_TIME, SET_LOCATION, GET_TIME, GET_LOCATION];
