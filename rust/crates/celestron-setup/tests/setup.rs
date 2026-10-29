//! Set Time and Set Location: byte layouts, read-back confirmation, the site
//! file, and that coordinates never reach `Debug` or error text. All sites
//! here are fictitious.

use cwb_celestron_discovery::Outcome;
use cwb_celestron_setup::backlash::{self, Slot};
use cwb_celestron_setup::{
    Dms, HandTime, Location, ReadBack, SetupError, Site,
    apply::until_next_second,
    command::ALLOWED_FIRST_BYTES,
    fake::{FakeSetter, Quirks},
    set_location, set_time,
};
use jiff::{Timestamp, civil::date, tz::TimeZone};

fn site(text: &str) -> Result<Site, SetupError> {
    Site::parse(text)
}

fn fictitious() -> Site {
    site("name = \"Test\"\nlatitude = 45.5\nlongitude = -110.25\n").unwrap()
}

fn time() -> HandTime {
    // 12:34:56 on 29 Oct 2026, UTC−8 standard with daylight saving on.
    HandTime::from_parts(date(2026, 10, 29).at(12, 34, 56, 0), -8, true).unwrap()
}

#[test]
fn set_time_bytes_follow_the_documented_layout() {
    assert_eq!(time().bytes(), [b'H', 12, 34, 56, 10, 29, 26, 248, 1]);
    let utc = time().timestamp().unwrap();
    assert_eq!(utc, "2026-10-29T19:34:56Z".parse::<Timestamp>().unwrap());
}

#[test]
fn local_time_daylight_saving_and_offset_come_from_the_zone() {
    let tz = TimeZone::get("America/Denver").unwrap();
    let summer = HandTime::at("2026-07-01T18:00:00Z".parse().unwrap(), &tz).unwrap();
    assert_eq!(
        (summer.hour, summer.standard_offset_hours, summer.dst),
        (12, -7, true)
    );
    let winter = HandTime::at("2026-12-01T18:00:00Z".parse().unwrap(), &tz).unwrap();
    assert_eq!(
        (winter.hour, winter.standard_offset_hours, winter.dst),
        (11, -7, false)
    );
}

#[test]
fn zones_that_are_not_whole_hours_are_refused() {
    let tz = TimeZone::get("Asia/Kolkata").unwrap();
    assert!(matches!(
        HandTime::at("2026-07-01T18:00:00Z".parse().unwrap(), &tz),
        Err(SetupError::Time(_))
    ));
}

#[test]
fn coordinates_round_to_whole_arcseconds_with_carry() {
    let d = Dms::from_degrees(-(10.0 + 59.0 / 60.0 + 59.6 / 3600.0));
    assert_eq!(
        (d.degrees, d.minutes, d.seconds, d.negative),
        (11, 0, 0, true)
    );
    let d = Dms::from_degrees(-0.0001 / 3600.0);
    assert!(!d.negative, "a value that rounds to zero has no sign");
}

#[test]
fn set_location_bytes_follow_the_documented_layout() {
    // 45° 30′ 0″ N, 110° 15′ 0″ W.
    assert_eq!(
        Location::of(&fictitious()).bytes(),
        [b'W', 45, 30, 0, 0, 110, 15, 0, 1]
    );
}

#[test]
fn a_setting_that_reads_back_the_same_is_confirmed() {
    let mut hc = FakeSetter::default();
    assert!(set_time(&mut hc, &time()).confirmed());
    assert!(set_location(&mut hc, &Location::of(&fictitious())).confirmed());
    let firsts: Vec<u8> = hc.received.iter().map(|c| c[0]).collect();
    assert_eq!(firsts, b"HhWw");
}

#[test]
fn a_clock_more_than_two_seconds_off_or_a_forgotten_setting_is_reported() {
    let mut drifting = FakeSetter::new(Quirks {
        clock_offset_s: 3,
        ..Quirks::default()
    });
    assert!(matches!(
        set_time(&mut drifting, &time()).read_back,
        Some(ReadBack::Differs(_))
    ));
    let mut forgets = FakeSetter::new(Quirks {
        forgets: true,
        ..Quirks::default()
    });
    let applied = set_location(&mut forgets, &Location::of(&fictitious()));
    assert_eq!(applied.acknowledged, Outcome::Ok);
    let Some(ReadBack::Differs(why)) = applied.read_back else {
        panic!("{applied:?}")
    };
    assert!(!why.contains("45"), "{why}");
}

#[test]
fn an_unacknowledged_set_skips_the_read_back() {
    let mut hc = FakeSetter::new(Quirks {
        silent: true,
        ..Quirks::default()
    });
    let applied = set_time(&mut hc, &time());
    assert_eq!(applied.acknowledged, Outcome::Timeout);
    assert_eq!(applied.read_back, None);
    assert_eq!(hc.received.len(), 1);
}

#[test]
fn only_time_and_location_commands_can_be_sent() {
    let mut hc = FakeSetter::default();
    set_time(&mut hc, &time());
    set_location(&mut hc, &Location::of(&fictitious()));
    for cmd in &hc.received {
        assert!(ALLOWED_FIRST_BYTES.contains(&cmd[0]), "{cmd:?}");
    }
    // Motion, goto, sync, tracking: none can begin a command.
    for b in b"RrBbSsMTPKz" {
        assert!(!ALLOWED_FIRST_BYTES.contains(b));
    }
}

#[test]
fn coordinates_stay_out_of_debug_and_errors() {
    let s = fictitious();
    for text in [format!("{s:?}"), format!("{:?}", Location::of(&s))] {
        assert!(!text.contains("45") && !text.contains("110"), "{text}");
    }
    let err = site("latitude = 45.5\nlongitude = \"110.25 W\"\n").unwrap_err();
    assert!(!err.to_string().contains("110"), "{err}");
}

#[test]
fn the_site_file_rejects_placeholders_ranges_and_unknown_keys() {
    assert!(site("latitude = 0.0\nlongitude = 0.0\n").is_err());
    assert!(site("latitude = 95.0\nlongitude = 10.0\n").is_err());
    assert!(site("latitude = 45.5\nlongitude = 190.0\n").is_err());
    assert!(site("latitude = 45.5\nlongitude = 10.0\nelevation = 5\n").is_err());
    let example = include_str!("../../../../config/site.example.toml");
    assert!(
        site(example).is_err(),
        "the template's placeholders must not pass as a site"
    );
}

#[test]
fn the_time_is_sent_on_a_whole_second() {
    let ts: Timestamp = "2026-10-29T19:34:56.25Z".parse().unwrap();
    assert_eq!(until_next_second(ts).as_millis(), 750);
}

#[test]
fn backlash_bytes_follow_libnexstar() {
    let azm_pos = Slot::parse("azm+").unwrap();
    assert_eq!(azm_pos.get_bytes(), [b'P', 1, 16, 0x40, 0, 0, 0, 1]);
    assert_eq!(azm_pos.set_bytes(0), [b'P', 2, 16, 0x10, 0, 0, 0, 0]);
    let alt_neg = Slot::parse("alt-").unwrap();
    assert_eq!(alt_neg.set_bytes(99), [b'P', 2, 17, 0x11, 99, 0, 0, 0]);
    assert_eq!(alt_neg.to_string(), "alt-");
    assert!(Slot::parse("ra+").is_none());
}

#[test]
fn backlash_is_set_and_confirmed_by_read_back() {
    let mut hc = FakeSetter::default();
    hc.backlash = [[50, 50], [50, 50]];
    for slot in Slot::ALL {
        assert_eq!(backlash::read(&mut hc, slot), Some(50));
        assert!(backlash::set(&mut hc, slot, 0).confirmed());
    }
    assert_eq!(hc.backlash, [[0, 0], [0, 0]]);
    // Only backlash gets and sets went out: pass-through to the motors.
    for cmd in &hc.received {
        let get = cmd[1] == 1 && [0x40, 0x41].contains(&cmd[3]) && cmd[4..] == [0, 0, 0, 1];
        let set = cmd[1] == 2 && [0x10, 0x11].contains(&cmd[3]) && cmd[5..] == [0, 0, 0];
        assert!(
            cmd[0] == b'P' && [16, 17].contains(&cmd[2]) && (get || set),
            "{cmd:?}"
        );
    }
}

#[test]
fn a_backlash_value_that_does_not_take_is_reported() {
    let mut hc = FakeSetter::new(Quirks {
        forgets: true,
        ..Quirks::default()
    });
    hc.backlash = [[50, 50], [50, 50]];
    let applied = backlash::set(&mut hc, Slot::ALL[0], 0);
    assert_eq!(applied.acknowledged, Outcome::Ok);
    assert!(
        matches!(applied.read_back, Some(ReadBack::Differs(ref why)) if why.contains("reads back 50"))
    );
}
