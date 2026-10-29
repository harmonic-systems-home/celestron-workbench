//! The catalog can't express motion or a write: every sendable command is a
//! documented "get" (ADR 0010).

use cwb_celestron_discovery::query::{
    self, ALLOWED_FIRST_BYTES, Device, GET_BACKLASH_NEGATIVE, GET_BACKLASH_POSITIVE,
    GET_DEVICE_VERSION, Query, Value,
};

fn every_query() -> Vec<Query> {
    let mut all = query::plan(10);
    all.extend((0..=255u8).map(Query::Echo));
    all.push(Query::PreciseAzmAlt);
    all
}

#[test]
fn every_sendable_command_is_a_documented_get() {
    for q in every_query() {
        let bytes = q.bytes();
        assert!(
            ALLOWED_FIRST_BYTES.contains(&bytes[0]),
            "{q}: starts with {:?}",
            bytes[0] as char
        );
        // Documented motion and state changes: slews, goto, sync, cancel,
        // set tracking, time, location; none may begin a command.
        assert!(!b"RrBbSsMTHW".contains(&bytes[0]), "{q}");
        if bytes[0] == b'P' {
            assert_eq!(bytes.len(), 8, "{q}");
            assert_eq!(bytes[1], 1, "{q}: one data byte, a get");
            assert!([16, 17].contains(&bytes[2]), "{q}: motors only");
            // Gets only: version (2-byte reply) or backlash (1-byte reply).
            match bytes[3] {
                GET_DEVICE_VERSION => assert_eq!(bytes[7], 2, "{q}"),
                GET_BACKLASH_POSITIVE | GET_BACKLASH_NEGATIVE => assert_eq!(bytes[7], 1, "{q}"),
                other => panic!("{q}: pass-through message {other:#x}"),
            }
            assert_eq!(bytes[4..7], [0, 0, 0], "{q}: no data sent");
        } else if bytes[0] == b'K' {
            assert_eq!(bytes.len(), 2);
        } else {
            assert_eq!(bytes.len(), 1, "{q}");
        }
    }
}

#[test]
fn location_and_time_are_never_queried() {
    for q in every_query() {
        let first = q.bytes()[0];
        assert!(first != b'w' && first != b'h', "{q}");
    }
}

#[test]
fn replies_decode_as_documented() {
    // The document's own examples.
    let v = Query::PreciseAzmAlt.decode(b"12AB0500,40000500").unwrap();
    let Value::Angles {
        azm_deg, alt_deg, ..
    } = v
    else {
        panic!("{v:?}")
    };
    assert!((azm_deg - 26.252).abs() < 1e-3, "{azm_deg}");
    assert!((alt_deg - 90.0).abs() < 0.01, "{alt_deg}");
    let Value::Angles { alt_deg, .. } = Query::AzmAlt.decode(b"34AB,12CE").unwrap() else {
        panic!()
    };
    assert!((alt_deg - 26.4441).abs() < 1e-3, "{alt_deg}");

    assert_eq!(
        Query::Version.decode(&[4, 21]),
        Some(Value::Version {
            major: 4,
            minor: 21
        })
    );
    assert_eq!(Query::GotoInProgress.decode(b"0"), Some(Value::Flag(false)));
    assert_eq!(
        Query::GotoInProgress.decode(&[0]),
        None,
        "ASCII, not binary"
    );
    assert_eq!(
        Query::AlignmentComplete.decode(&[1]),
        Some(Value::Flag(true))
    );
    assert_eq!(Query::PreciseAzmAlt.decode(b"12AB0500;40000500"), None);
    assert_eq!(Query::DeviceVersion(Device::AzmMotor).decode(&[7]), None);
    assert_eq!(
        Query::Model.decode(&[22]).unwrap().to_string(),
        "22 (NexStar Evolution)"
    );
}
