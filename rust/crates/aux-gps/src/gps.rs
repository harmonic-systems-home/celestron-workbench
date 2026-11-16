//! The GPS's AUX messages and the replies this crate sends.
//!
//! Three community sources agree on the IDs and layouts (docs/references.md):
//! Paquette's *NexStar AUX Command Set* (chapter 5), the nexstar_gps Arduino
//! firmware, and platini2/celestron-aux's GPS emulator. All three describe a
//! GPS that only answers requests; none says a GPS sends anything unasked.

use crate::packet::Packet;

/// The GPS's bus address.
pub const GPS: u8 = 0xB0;

/// Hand controller addresses: NexStar (0x04), NexStar+ (0x0D) and the
/// StarSense hand controller (0x0E, seen on this mount).
pub const HAND_CONTROLLERS: [u8; 3] = [0x04, 0x0D, 0x0E];

pub const GET_LAT: u8 = 0x01;
pub const GET_LONG: u8 = 0x02;
pub const GET_DATE: u8 = 0x03;
pub const GET_YEAR: u8 = 0x04;
pub const GET_SAT_INFO: u8 = 0x07;
pub const GET_TIME: u8 = 0x33;
pub const TIME_VALID: u8 = 0x36;
pub const LINKED: u8 = 0x37;
pub const GET_HW_VER: u8 = 0x55;
pub const GET_VER: u8 = 0xFE;

/// Every ID this crate can send a reply for.
pub const IDS: [u8; 10] = [
    GET_LAT,
    GET_LONG,
    GET_DATE,
    GET_YEAR,
    GET_SAT_INFO,
    GET_TIME,
    TIME_VALID,
    LINKED,
    GET_HW_VER,
    GET_VER,
];

/// What a hand controller asks when it views a GPS's time and site
/// (Paquette, "View time/site"), in that order: pushed unasked by the test.
pub const PUSH_SEQUENCE: [u8; 7] = [
    LINKED, TIME_VALID, GET_YEAR, GET_DATE, GET_TIME, GET_LAT, GET_LONG,
];

pub fn name(id: u8) -> &'static str {
    match id {
        GET_LAT => "GPS_GET_LAT",
        GET_LONG => "GPS_GET_LONG",
        GET_DATE => "GPS_GET_DATE",
        GET_YEAR => "GPS_GET_YEAR",
        GET_SAT_INFO => "GPS_GET_SAT_INFO",
        0x08 => "GPS_GET_RCVR_STATUS",
        GET_TIME => "GPS_GET_TIME",
        TIME_VALID => "GPS_TIME_VALID",
        LINKED => "GPS_LINKED",
        GET_HW_VER => "GPS_GET_HW_VER",
        0xA0 => "GPS_GET_COMPASS",
        GET_VER => "GPS_GET_VER",
        _ => "unknown",
    }
}

/// A place far from any observing site here, shown plainly on a hand
/// controller: the Royal Observatory, Greenwich, 51.4769° N, 0.0005° W.
pub const DECOY: Place = Place {
    latitude: 51.4769,  // Greenwich, public. privacy-check: allow
    longitude: -0.0005, // Greenwich, public. privacy-check: allow
};

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Place {
    pub latitude: f64,
    pub longitude: f64,
}

/// A UTC date and time, as the GPS reports it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Utc {
    pub year: u16,
    pub month: u8,
    pub day: u8,
    pub hour: u8,
    pub minute: u8,
    pub second: u8,
}

impl Utc {
    /// An obviously wrong time, so a change on the hand controller shows.
    pub const DECOY: Utc = Utc {
        year: 2030,
        month: 1,
        day: 1,
        hour: 12,
        minute: 0,
        second: 0,
    };

    pub fn from_timestamp(t: jiff::Timestamp) -> Self {
        let d = t.to_zoned(jiff::tz::TimeZone::UTC).datetime();
        Utc {
            year: d.year() as u16,
            month: d.month() as u8,
            day: d.day() as u8,
            hour: d.hour() as u8,
            minute: d.minute() as u8,
            second: d.second() as u8,
        }
    }
}

/// The fix the test reports. The place is always [`DECOY`]: there is no
/// way to give it another.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Fix {
    time: Utc,
}

/// How the time moves on while the test runs.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Clock {
    /// Stays at the given time.
    Fixed(Utc),
    /// Follows this Mac's clock.
    Now,
}

impl Fix {
    pub fn at(time: Utc) -> Self {
        Fix { time }
    }

    pub fn time(&self) -> Utc {
        self.time
    }

    pub fn place(&self) -> Place {
        DECOY
    }

    /// The reply data for a GPS message, or `None` for one the GPS
    /// doesn't answer here (receiver status, compass, unknown IDs).
    pub fn reply_data(&self, id: u8) -> Option<Vec<u8>> {
        let t = self.time;
        Some(match id {
            LINKED | TIME_VALID => vec![1],
            GET_YEAR => t.year.to_be_bytes().to_vec(),
            GET_DATE => vec![t.month, t.day],
            GET_TIME => vec![t.hour, t.minute, t.second],
            GET_LAT => angle24(DECOY.latitude).to_vec(),
            GET_LONG => angle24(DECOY.longitude).to_vec(),
            // Satellites in view, then tracked (Paquette); a good fix.
            GET_SAT_INFO => vec![12, 9],
            // What Celestron GPS units answer (Paquette, both emulators).
            GET_HW_VER => vec![0xAB],
            GET_VER => vec![1, 0],
            _ => return None,
        })
    }

    /// The only way this crate makes a packet to send: from the GPS, to a
    /// hand controller, with a GPS reply.
    pub fn packet(&self, id: u8, hand_controller: u8) -> Option<Packet> {
        if !HAND_CONTROLLERS.contains(&hand_controller) {
            return None;
        }
        Some(Packet {
            src: GPS,
            dst: hand_controller,
            id,
            data: self.reply_data(id)?,
        })
    }
}

/// Degrees as a 24-bit signed fraction of a full turn, big-endian
/// (Paquette: 0x20 0x3E 0x35 is +45°20′30.17″).
pub fn angle24(degrees: f64) -> [u8; 3] {
    let units = (degrees / 360.0 * 16_777_216.0).round() as i64;
    let u = units.rem_euclid(1 << 24) as u32;
    [(u >> 16) as u8, (u >> 8) as u8, u as u8]
}

/// The inverse of [`angle24`].
pub fn degrees24(bytes: [u8; 3]) -> f64 {
    let u = (u32::from(bytes[0]) << 16) | (u32::from(bytes[1]) << 8) | u32::from(bytes[2]);
    let signed = if u >= 1 << 23 {
        i64::from(u) - (1 << 24)
    } else {
        i64::from(u)
    };
    signed as f64 * 360.0 / 16_777_216.0
}
