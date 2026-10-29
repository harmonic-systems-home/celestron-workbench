//! Sends a setting, then reads it back to confirm the hand controller kept
//! it. Read-back results say whether the values match, never what they are.

use cwb_celestron_discovery::{Link, Outcome, transact};
use jiff::Timestamp;

use crate::command::{GET_LOCATION, GET_TIME, HandTime, Location};

/// The hand controller's clock may tick between the set and the read-back.
pub const TIME_TOLERANCE_S: i64 = 2;

#[derive(Debug, Clone, PartialEq)]
pub enum ReadBack {
    Matches,
    Differs(String),
    /// The set was acknowledged but the read-back went unanswered.
    NotAnswered(Outcome),
}

#[derive(Debug, Clone, PartialEq)]
pub struct Applied {
    /// The set command's acknowledgement (`#`).
    pub acknowledged: Outcome,
    /// `None` when the set wasn't acknowledged, so no read-back was tried.
    pub read_back: Option<ReadBack>,
}

impl Applied {
    pub fn confirmed(&self) -> bool {
        self.read_back == Some(ReadBack::Matches)
    }
}

pub fn set_time(link: &mut impl Link, time: &HandTime) -> Applied {
    let (acknowledged, _) = transact(link, &time.bytes(), 0, false);
    if acknowledged != Outcome::Ok {
        return Applied {
            acknowledged,
            read_back: None,
        };
    }
    let (outcome, got) = transact(link, &[GET_TIME], 8, false);
    let read_back = match (outcome, HandTime::decode(got.get(..8).unwrap_or_default())) {
        (Outcome::Ok, Some(read)) => compare_time(time, &read),
        (Outcome::Ok, None) => ReadBack::Differs("the read-back isn't a valid time".into()),
        (outcome, _) => ReadBack::NotAnswered(outcome),
    };
    Applied {
        acknowledged,
        read_back: Some(read_back),
    }
}

fn compare_time(sent: &HandTime, read: &HandTime) -> ReadBack {
    if (sent.standard_offset_hours, sent.dst) != (read.standard_offset_hours, read.dst) {
        return ReadBack::Differs(format!("the hand controller reads back {read}"));
    }
    match (sent.timestamp(), read.timestamp()) {
        (Some(a), Some(b)) => {
            let diff = b.as_second() - a.as_second();
            if diff.abs() <= TIME_TOLERANCE_S {
                ReadBack::Matches
            } else {
                ReadBack::Differs(format!(
                    "the hand controller's clock reads {diff:+} s from the time sent"
                ))
            }
        }
        _ => ReadBack::Differs(format!("the hand controller reads back {read}")),
    }
}

pub fn set_location(link: &mut impl Link, location: &Location) -> Applied {
    let (acknowledged, _) = transact(link, &location.bytes(), 0, false);
    if acknowledged != Outcome::Ok {
        return Applied {
            acknowledged,
            read_back: None,
        };
    }
    let (outcome, got) = transact(link, &[GET_LOCATION], 8, false);
    let read_back = match outcome {
        Outcome::Ok if got[..8] == location.payload() => ReadBack::Matches,
        Outcome::Ok => ReadBack::Differs("the location read back isn't the one sent".into()),
        outcome => ReadBack::NotAnswered(outcome),
    };
    Applied {
        acknowledged,
        read_back: Some(read_back),
    }
}

/// Seconds from `now` to the next whole second, so a time sent then is
/// accurate to the link's few milliseconds rather than up to a second.
pub fn until_next_second(now: Timestamp) -> std::time::Duration {
    let nanos = now.subsec_nanosecond();
    std::time::Duration::from_nanos(
        (1_000_000_000 - i64::from(nanos)).rem_euclid(1_000_000_000) as u64
    )
}
