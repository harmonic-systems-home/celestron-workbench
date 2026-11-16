use std::time::Duration;

use cwb_aux_gps::{
    gps::{self, Clock, DECOY, Fix, GPS, HAND_CONTROLLERS, Utc, angle24, degrees24},
    link::FakeLink,
    packet::{Framer, Packet, checksum},
    run::{Event, Plan, run},
};

const HC: u8 = 0x0E;

fn dms(d: f64, m: f64, s: f64) -> f64 {
    d.signum() * (d.abs() + m / 60.0 + s / 3600.0)
}

#[test]
fn angles_match_paquettes_examples() {
    // NexStar AUX Command Set, "View time/site".
    assert_eq!(angle24(dms(45.0, 20.0, 30.17)), [0x20, 0x3E, 0x35]);
    assert_eq!(angle24(dms(-75.0, 54.0, 16.35)), [0xCA, 0x06, 0x00]);
    let back = degrees24([0xCA, 0x06, 0x00]);
    assert!((back - dms(-75.0, 54.0, 16.35)).abs() < 360.0 / 16_777_216.0);
}

#[test]
fn year_date_and_time_match_paquettes_layout() {
    let fix = Fix::at(Utc {
        year: 2003,
        month: 1,
        day: 16,
        hour: 17,
        minute: 43,
        second: 22,
    });
    assert_eq!(fix.reply_data(gps::GET_YEAR), Some(vec![0x07, 0xD3]));
    assert_eq!(fix.reply_data(gps::GET_DATE), Some(vec![0x01, 0x10]));
    assert_eq!(fix.reply_data(gps::GET_TIME), Some(vec![0x11, 0x2B, 0x16]));
    assert_eq!(fix.reply_data(gps::LINKED), Some(vec![1]));
    assert_eq!(fix.reply_data(gps::TIME_VALID), Some(vec![1]));
}

#[test]
fn the_place_is_always_the_decoy() {
    let fix = Fix::at(Utc::DECOY);
    assert_eq!(fix.place(), DECOY);
    assert_eq!(
        fix.reply_data(gps::GET_LAT),
        Some(angle24(DECOY.latitude).to_vec())
    );
    assert_eq!(
        fix.reply_data(gps::GET_LONG),
        Some(angle24(DECOY.longitude).to_vec())
    );
}

#[test]
fn packets_go_only_from_the_gps_to_a_hand_controller() {
    let fix = Fix::at(Utc::DECOY);
    for id in 0..=255u8 {
        for dst in 0..=255u8 {
            if let Some(p) = fix.packet(id, dst) {
                assert_eq!(p.src, GPS);
                assert!(HAND_CONTROLLERS.contains(&p.dst), "to {dst:#04x}");
                assert!(gps::IDS.contains(&p.id), "id {id:#04x}");
            }
        }
    }
    // Never to a motor (0x10, 0x11) or anything else.
    assert!(fix.packet(gps::GET_TIME, 0x10).is_none());
    assert!(fix.packet(gps::GET_TIME, 0x20).is_none());
    // No reply for receiver status or compass.
    assert!(fix.packet(0x08, HC).is_none());
    assert!(fix.packet(0xA0, HC).is_none());
}

#[test]
fn encoded_packets_have_the_aux_layout() {
    let p = Fix::at(Utc::DECOY).packet(gps::LINKED, HC).unwrap();
    let bytes = p.encode();
    assert_eq!(bytes[..5], [0x3B, 0x04, 0xB0, 0x0E, 0x37]);
    assert_eq!(bytes[5], 1);
    assert_eq!(bytes[6], checksum(&bytes[1..6]));
}

#[test]
fn the_framer_handles_split_joined_and_noisy_streams() {
    let a = Packet {
        src: 0x0E,
        dst: 0x10,
        id: 0x01,
        data: vec![],
    };
    let b = Packet {
        src: 0x10,
        dst: 0x0E,
        id: 0x01,
        data: vec![0x12, 0x34, 0x56],
    };
    let mut stream = vec![0x00, 0x3B, 0xFF];
    stream.extend(a.encode());
    stream.extend(b.encode());
    let mut f = Framer::default();
    let mut got = f.push(&stream[..6]);
    got.extend(f.push(&stream[6..]));
    assert_eq!(got, vec![a, b]);
}

/// Advances 100 ms per call.
fn ticker() -> impl FnMut() -> Duration {
    let mut t = Duration::ZERO;
    move || {
        let now = t;
        t += Duration::from_millis(100);
        now
    }
}

fn plan(push_every: Option<Duration>) -> Plan {
    Plan {
        hand_controller: HC,
        clock: Clock::Fixed(Utc::DECOY),
        push_every,
        gap: Duration::ZERO,
        duration: Duration::from_secs(1),
    }
}

#[test]
fn pushes_the_sequence_and_recognises_its_echo() {
    let mut link = FakeLink::default();
    let first = Fix::at(Utc::DECOY).packet(gps::LINKED, HC).unwrap();
    link.incoming.push_back(Vec::new());
    link.incoming.push_back(first.encode());
    let mut events = Vec::new();
    let s = run(
        &mut link,
        &plan(Some(Duration::from_secs(10))),
        &mut ticker(),
        &mut || Utc::DECOY,
        &mut |e| events.push(e.clone()),
    )
    .unwrap();
    assert_eq!(s.pushed, gps::PUSH_SEQUENCE.len());
    assert_eq!(s.echoed, 1);
    assert_eq!(s.other_gps, 0);
    assert_eq!(link.sent.len(), gps::PUSH_SEQUENCE.len());
    assert!(events.contains(&Event::Echo(first)));
}

#[test]
fn answers_a_hand_controllers_gps_request() {
    let mut link = FakeLink::default();
    let ask = |id| Packet {
        src: HC,
        dst: GPS,
        id,
        data: vec![],
    };
    link.incoming.push_back(ask(gps::LINKED).encode());
    link.incoming.push_back(ask(gps::GET_TIME).encode());
    link.incoming.push_back(ask(0xA0).encode());
    let s = run(
        &mut link,
        &plan(None),
        &mut ticker(),
        &mut || Utc::DECOY,
        &mut |_| {},
    )
    .unwrap();
    assert_eq!(s.pushed, 0);
    assert_eq!(s.answered, 2);
    assert_eq!(s.from_hand_controller, 3);
    assert_eq!(s.gps_requests.get(&(HC, 0xA0)), Some(&1));
    let fix = Fix::at(Utc::DECOY);
    assert_eq!(
        link.sent,
        vec![
            fix.packet(gps::LINKED, HC).unwrap().encode(),
            fix.packet(gps::GET_TIME, HC).unwrap().encode(),
        ]
    );
}

#[test]
fn a_request_from_a_non_controller_is_heard_but_not_answered() {
    let mut link = FakeLink::default();
    link.incoming.push_back(
        Packet {
            src: 0x20,
            dst: GPS,
            id: gps::GET_TIME,
            data: vec![],
        }
        .encode(),
    );
    let s = run(
        &mut link,
        &plan(None),
        &mut ticker(),
        &mut || Utc::DECOY,
        &mut |_| {},
    )
    .unwrap();
    assert_eq!(s.answered, 0);
    assert!(link.sent.is_empty());
}

#[test]
fn now_follows_the_wall_clock() {
    let t: jiff::Timestamp = "2026-11-12T03:04:05Z".parse().unwrap();
    let u = Utc::from_timestamp(t);
    assert_eq!(
        (u.year, u.month, u.day, u.hour, u.minute, u.second),
        (2026, 11, 12, 3, 4, 5)
    );
}
