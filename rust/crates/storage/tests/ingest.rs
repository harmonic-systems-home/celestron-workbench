//! Repository tests: storing protocol messages and reading sessions back.

use std::io::Cursor;

use cwb_protocol::{
    AccelSample, AttitudeReferenceFrame, Bye, ByeReason, ClockResult, DeviceInfo,
    DeviceMotionSample, Environment, ErrorCode, Event, EventKind, GyroSample, Hello, Location,
    LocationStatus, MagnetometerSample, Marker, Message, PROTOCOL_VERSION, Quaternion, Sample,
    SampleBatch, SensorAvailability, Seq, Severity, Site, Stream,
};
use cwb_storage::{
    Connection, HelloOutcome, StorageError, Store, StoreConfig, clockfit, open_in_memory, sessions,
};
use serde_json::json;

const SESSION: &str = "11111111-1111-4111-8111-111111111111";
const DEVICE: &str = "22222222-2222-4222-8222-222222222222";
const OTHER_DEVICE: &str = "33333333-3333-4333-8333-333333333333";
const BOOT: &str = "44444444-4444-4444-8444-444444444444";

fn store_with(boot_id: &str, conn: Connection) -> Store {
    Store::new(
        conn,
        StoreConfig {
            mac_clock_boot_id: boot_id.into(),
            software_versions: json!({ "test": "1" }),
        },
    )
}

fn store() -> Store {
    store_with("mac-run-1", open_in_memory().unwrap())
}

fn hello_from(device: &str) -> Hello {
    Hello {
        protocol_version: PROTOCOL_VERSION,
        session_id: SESSION.into(),
        device: DeviceInfo {
            device_id: device.into(),
            vendor: "Apple".into(),
            model: "iPhone".into(),
            os_version: "26.0".into(),
            app_version: "0.1.0 (1)".into(),
            boot_id: BOOT.into(),
        },
        sensor_availability: SensorAvailability {
            device_motion: true,
            gyro: true,
            accel: true,
            magnetometer: true,
        },
        streams: vec![
            Stream::DeviceMotion,
            Stream::Gyro,
            Stream::Accel,
            Stream::Magnetometer,
        ],
        attitude_reference_frame: AttitudeReferenceFrame::XArbitraryZVertical,
        requested_interval_s: 0.01,
        accel_g0_m_s2: 9.80665,
    }
}

fn hello() -> Hello {
    hello_from(DEVICE)
}

/// One sample of each stream in turn, with awkward floating-point values.
fn sample(seq: Seq) -> Sample {
    let t_ns = 512_000_000_000 + seq as i64 * 2_500_000;
    let f = seq as f64;
    match seq % 4 {
        0 => Sample::DeviceMotion(DeviceMotionSample {
            seq,
            t_ns,
            attitude: Quaternion {
                w: 0.999_966_445_064_095,
                x: 0.008_009_963_963_551_428,
                y: -0.001_648_296_719_702_265,
                z: 9.726_661_313_055_892e-18 * f,
            },
            rotation_rate: [0.1 + f, -0.2, 1e-300],
            gravity: [-0.032, -0.157, -9.805_338_332_879_543],
            user_accel: [0.0, -0.0, 0.017_918_134_935_852_138],
            magnetic_field_ut: None,
            magnetic_accuracy: None,
        }),
        1 => Sample::Gyro(GyroSample {
            seq,
            t_ns,
            rotation_rate: [-0.003_46, 0.001_27, f],
        }),
        2 => Sample::Accel(AccelSample {
            seq,
            t_ns,
            accel: [-0.0392, -0.1451, -9.8315],
        }),
        _ => Sample::Magnetometer(MagnetometerSample {
            seq,
            t_ns,
            magnetic_field_ut: [21.5, -4.2, -38.9],
        }),
    }
}

fn batch(first: Seq, last: Seq) -> SampleBatch {
    SampleBatch {
        protocol_version: PROTOCOL_VERSION,
        session_id: SESSION.into(),
        device_id: DEVICE.into(),
        first_seq: first,
        last_seq: last,
        samples: (first..=last).map(sample).collect(),
    }
}

fn bye(last_seq: Option<Seq>) -> Bye {
    Bye {
        protocol_version: PROTOCOL_VERSION,
        session_id: SESSION.into(),
        device_id: DEVICE.into(),
        last_seq,
        reason: ByeReason::OperatorStop,
    }
}

fn marker(id: &str) -> Marker {
    Marker {
        protocol_version: PROTOCOL_VERSION,
        session_id: SESSION.into(),
        device_id: DEVICE.into(),
        marker_id: id.into(),
        label: "flat".into(),
        t_ns: 512_010_000_000,
        notes: None,
    }
}

fn event() -> Event {
    Event {
        protocol_version: PROTOCOL_VERSION,
        session_id: SESSION.into(),
        device_id: DEVICE.into(),
        t_ns: 512_020_000_000,
        kind: EventKind::DroppedSamples,
        severity: Severity::Warning,
        detail: serde_json::from_value(json!({ "stream": "gyro", "count": 3, "total": 3 }))
            .unwrap(),
    }
}

const MAC_RUN_A: &str = "66666666-6666-4666-8666-666666666666";
const MAC_RUN_B: &str = "77777777-7777-4777-8777-777777777777";

/// An exchange every 2 s from phone time 512 s; the Mac clock reads
/// 3 s ahead with 1 ms each way and 20 µs turnaround.
/// A fictitious site.
fn site() -> Site {
    Site {
        protocol_version: PROTOCOL_VERSION,
        session_id: SESSION.into(),
        device_id: DEVICE.into(),
        site_id: "66666666-6666-4666-8666-666666666666".into(),
        t_ns: 512_001_000_000,
        environment: Environment::Indoor,
        location_status: LocationStatus::Fix,
        location: Some(Location {
            latitude: 45.5,
            longitude: -110.25,
            horizontal_accuracy_m: 35.0,
            altitude_m: None,
            vertical_accuracy_m: None,
            precise: true,
            fix_age_s: 1.5,
        }),
    }
}

fn clock_result(index: u64, mac_run: &str) -> ClockResult {
    let t1 = 512_000_000_000 + index as i64 * 2_000_000_000;
    let t2 = t1 + 3_000_000_000 + 1_000_000;
    ClockResult {
        protocol_version: PROTOCOL_VERSION,
        session_id: SESSION.into(),
        device_id: DEVICE.into(),
        exchange_index: index,
        phone_send_ns: t1,
        mac_receive_ns: t2,
        mac_send_ns: t2 + 20_000,
        phone_receive_ns: t1 + 2_020_000,
        mac_clock_boot_id: mac_run.into(),
    }
}

fn accepted(outcome: HelloOutcome) -> (bool, Option<Seq>) {
    match outcome {
        HelloOutcome::Accepted {
            created,
            highest_contiguous_seq,
        } => (created, highest_contiguous_seq),
        HelloOutcome::Rejected { code, reason } => panic!("rejected: {code:?} {reason}"),
    }
}

fn count(conn: &Connection, sql: &str) -> i64 {
    conn.query_row(sql, [], |r| r.get(0)).unwrap()
}

fn status(conn: &Connection) -> String {
    conn.query_row("SELECT status FROM sessions", [], |r| r.get(0))
        .unwrap()
}

fn mac_events(conn: &Connection, kind: &str) -> i64 {
    conn.query_row(
        "SELECT COUNT(*) FROM session_events WHERE source = 'mac' AND kind = ?1",
        [kind],
        |r| r.get(0),
    )
    .unwrap()
}

#[test]
fn hello_creates_the_session_and_a_reconnect_resumes_it() {
    let mut store = store();
    assert_eq!(accepted(store.hello(&hello(), 1).unwrap()), (true, None));
    store.batch(&batch(0, 9), 2).unwrap();
    assert_eq!(
        accepted(store.hello(&hello(), 3).unwrap()),
        (false, Some(9))
    );
    let conn = store.connection();
    assert_eq!(count(conn, "SELECT COUNT(*) FROM sessions"), 1);
    assert_eq!(
        count(
            conn,
            "SELECT COUNT(*) FROM devices WHERE role = 'imu_phone' AND streams IS NOT NULL"
        ),
        1
    );
    assert_eq!(status(conn), "recording");
    assert_eq!(mac_events(conn, "reconnected"), 1);
}

#[test]
fn a_second_device_cannot_join_a_session() {
    let mut store = store();
    accepted(store.hello(&hello(), 1).unwrap());
    let outcome = store.hello(&hello_from(OTHER_DEVICE), 2).unwrap();
    assert!(matches!(
        outcome,
        HelloOutcome::Rejected {
            code: ErrorCode::DeviceMismatch,
            ..
        }
    ));
}

#[test]
fn unsupported_protocol_versions_are_rejected() {
    let mut store = store();
    let mut h = hello();
    h.protocol_version = 2;
    assert!(matches!(
        store.hello(&h, 1).unwrap(),
        HelloOutcome::Rejected {
            code: ErrorCode::UnsupportedVersion,
            ..
        }
    ));
    assert_eq!(
        count(store.connection(), "SELECT COUNT(*) FROM sessions"),
        0
    );
}

#[test]
fn batches_need_a_known_session() {
    let mut store = store();
    assert!(matches!(
        store.batch(&batch(0, 3), 1),
        Err(StorageError::UnknownSession(_))
    ));
}

#[test]
fn in_order_batches_advance_the_acknowledgement_and_resends_are_skipped() {
    let mut store = store();
    accepted(store.hello(&hello(), 1).unwrap());
    let first = store.batch(&batch(0, 9), 2).unwrap();
    assert_eq!((first.stored, first.highest_contiguous_seq), (10, Some(9)));
    let second = store.batch(&batch(10, 19), 3).unwrap();
    assert_eq!(second.highest_contiguous_seq, Some(19));

    // A resend after reconnecting overlaps what is stored.
    let resend = store.batch(&batch(5, 24), 4).unwrap();
    assert_eq!(
        (resend.stored, resend.duplicates, resend.conflicts),
        (5, 15, 0)
    );
    assert_eq!(resend.highest_contiguous_seq, Some(24));
    assert_eq!(resend.gap, None);
    let conn = store.connection();
    assert_eq!(count(conn, "SELECT COUNT(*) FROM sensor_samples"), 25);
    assert_eq!(mac_events(conn, "duplicate_samples"), 1);
    // The original receive time is kept, not overwritten by the resend.
    assert_eq!(
        count(
            conn,
            "SELECT receive_mac_ns FROM sensor_samples WHERE seq = 5"
        ),
        2
    );
}

#[test]
fn a_gap_holds_the_acknowledgement_until_it_is_filled() {
    let mut store = store();
    accepted(store.hello(&hello(), 1).unwrap());
    store.batch(&batch(0, 9), 2).unwrap();
    let ahead = store.batch(&batch(20, 29), 3).unwrap();
    assert_eq!(ahead.gap, Some((10, 20)));
    assert_eq!(ahead.highest_contiguous_seq, Some(9));
    assert_eq!(mac_events(store.connection(), "sequence_gap"), 1);

    let report = sessions::validate(store.connection(), SESSION).unwrap();
    assert_eq!(report.devices[0].missing, vec![(10, 19)]);

    let filled = store.batch(&batch(10, 19), 4).unwrap();
    assert_eq!(filled.gap, None);
    assert_eq!(filled.highest_contiguous_seq, Some(29));
    // A hello on a fresh store (e.g. after a Mac restart) computes the same.
    let conn = store.into_connection();
    let mut restarted = store_with("mac-run-2", conn);
    assert_eq!(
        accepted(restarted.hello(&hello(), 5).unwrap()),
        (false, Some(29))
    );
}

#[test]
fn a_batch_starting_after_zero_is_a_gap_with_nothing_to_acknowledge() {
    let mut store = store();
    accepted(store.hello(&hello(), 1).unwrap());
    let outcome = store.batch(&batch(4, 7), 2).unwrap();
    assert_eq!(outcome.gap, Some((0, 4)));
    assert_eq!(outcome.highest_contiguous_seq, None);
}

#[test]
fn conflicting_duplicates_are_flagged_and_never_overwrite() {
    let mut store = store();
    accepted(store.hello(&hello(), 1).unwrap());
    store.batch(&batch(0, 3), 2).unwrap();
    let mut altered = batch(0, 3);
    if let Sample::Gyro(g) = &mut altered.samples[1] {
        g.t_ns += 1;
    }
    let outcome = store.batch(&altered, 3).unwrap();
    assert_eq!(
        (outcome.stored, outcome.duplicates, outcome.conflicts),
        (0, 3, 1)
    );
    let conn = store.connection();
    assert_eq!(mac_events(conn, "conflicting_samples"), 1);
    assert_eq!(
        count(
            conn,
            "SELECT source_phone_ns FROM sensor_samples WHERE seq = 1"
        ),
        512_002_500_000
    );
    let report = sessions::validate(conn, SESSION).unwrap();
    assert!(report.problems.iter().any(|p| p.contains("conflict")));
}

#[test]
fn malformed_batches_are_refused_without_storing_anything() {
    let mut store = store();
    accepted(store.hello(&hello(), 1).unwrap());
    let mut broken = batch(0, 3);
    broken.last_seq = 4;
    assert!(matches!(
        store.batch(&broken, 2),
        Err(StorageError::InvalidMessage(_))
    ));
    let mut reordered = batch(0, 3);
    reordered.samples.swap(1, 2);
    assert!(matches!(
        store.batch(&reordered, 2),
        Err(StorageError::InvalidMessage(_))
    ));
    assert_eq!(
        count(store.connection(), "SELECT COUNT(*) FROM sensor_samples"),
        0
    );
}

#[test]
fn values_are_stored_exactly_and_unavailable_ones_as_null() {
    let mut store = store();
    accepted(store.hello(&hello(), 1).unwrap());
    store.batch(&batch(0, 3), 2).unwrap();
    let conn = store.connection();
    let (z, tiny, accuracy_null, field_null): (f64, f64, bool, bool) = conn
        .query_row(
            "SELECT gravity_z, rotation_rate_z, magnetic_accuracy IS NULL, magnetic_field_x_ut IS NULL
             FROM sensor_samples WHERE seq = 0",
            [],
            |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)),
        )
        .unwrap();
    assert_eq!(z.to_bits(), (-9.805_338_332_879_543f64).to_bits());
    assert_eq!(tiny, 1e-300);
    assert!(accuracy_null && field_null);
    // Raw gyro rows leave every fused column null.
    assert_eq!(
        count(
            conn,
            "SELECT COUNT(*) FROM sensor_samples WHERE stream = 'gyro'
             AND q_w IS NULL AND gravity_x IS NULL AND accel_x IS NULL AND rotation_rate_x IS NOT NULL"
        ),
        1
    );
}

#[test]
fn markers_and_events_are_stored_once() {
    let mut store = store();
    accepted(store.hello(&hello(), 1).unwrap());
    assert!(
        store
            .marker(&marker("55555555-5555-4555-8555-555555555555"))
            .unwrap()
    );
    assert!(
        !store
            .marker(&marker("55555555-5555-4555-8555-555555555555"))
            .unwrap()
    );
    assert!(store.phone_event(&event(), 2).unwrap());
    assert!(!store.phone_event(&event(), 3).unwrap());
    let conn = store.connection();
    assert_eq!(count(conn, "SELECT COUNT(*) FROM markers"), 1);
    assert_eq!(
        count(
            conn,
            "SELECT COUNT(*) FROM session_events WHERE source = 'phone'"
        ),
        1
    );
    let report = sessions::validate(conn, SESSION).unwrap();
    assert_eq!(report.devices[0].dropped_on_phone, 3);
}

#[test]
fn a_site_is_stored_once_and_an_inconsistent_one_refused() {
    let mut store = store();
    assert!(matches!(
        store.site(&site(), 1),
        Err(StorageError::UnknownSession(_))
    ));
    accepted(store.hello(&hello(), 1).unwrap());
    assert!(store.site(&site(), 2).unwrap());
    assert!(!store.site(&site(), 3).unwrap(), "a resend is skipped");

    let mut no_fix = site();
    no_fix.site_id = "77777777-7777-4777-8777-777777777777".into();
    no_fix.location_status = LocationStatus::Denied;
    assert!(matches!(
        store.site(&no_fix, 4),
        Err(StorageError::InvalidMessage(_))
    ));
    no_fix.location = None;
    no_fix.environment = Environment::Outdoor;
    no_fix.t_ns += 1_000_000_000;
    assert!(store.site(&no_fix, 4).unwrap());

    let listed = sessions::list(store.connection()).unwrap();
    assert_eq!(
        listed[0].environment.as_deref(),
        Some("outdoor"),
        "the latest site"
    );
    assert_eq!(
        count(store.connection(), "SELECT COUNT(*) FROM session_sites"),
        2
    );
}

#[test]
fn location_debug_output_hides_coordinates() {
    let text = format!("{:?}", site());
    assert!(!text.contains("45.5") && !text.contains("110.25"), "{text}");
}

#[test]
fn bye_ends_a_complete_session() {
    let mut store = store();
    accepted(store.hello(&hello(), 1).unwrap());
    store.batch(&batch(0, 9), 2).unwrap();
    let outcome = store.bye(&bye(Some(9)), 3).unwrap();
    assert!(outcome.complete);
    assert_eq!(status(store.connection()), "ended");
    let report = sessions::validate(store.connection(), SESSION).unwrap();
    assert!(report.problems.is_empty(), "{:?}", report.problems);
}

#[test]
fn bye_with_samples_missing_leaves_the_session_incomplete_until_they_arrive() {
    let mut store = store();
    accepted(store.hello(&hello(), 1).unwrap());
    store.batch(&batch(0, 9), 2).unwrap();
    assert!(!store.bye(&bye(Some(19)), 3).unwrap().complete);
    assert_eq!(status(store.connection()), "incomplete");

    // The phone reconnects and resends, then says bye again.
    accepted(store.hello(&hello(), 4).unwrap());
    assert_eq!(status(store.connection()), "recording");
    store.batch(&batch(10, 19), 5).unwrap();
    assert!(store.bye(&bye(Some(19)), 6).unwrap().complete);
    assert_eq!(status(store.connection()), "ended");
}

#[test]
fn analyst_decisions_are_not_overwritten() {
    let mut store = store();
    accepted(store.hello(&hello(), 1).unwrap());
    store
        .connection()
        .execute("UPDATE sessions SET status = 'accepted'", [])
        .unwrap();
    store.bye(&bye(None), 2).unwrap();
    assert_eq!(status(store.connection()), "accepted");
    assert!(!store.mark_incomplete(SESSION, "test").unwrap());
}

#[test]
fn mark_incomplete_only_touches_recording_sessions() {
    let mut store = store();
    accepted(store.hello(&hello(), 1).unwrap());
    assert!(store.mark_incomplete(SESSION, "receiver stopped").unwrap());
    assert_eq!(status(store.connection()), "incomplete");
    assert!(!store.mark_incomplete(SESSION, "again").unwrap());
}

#[test]
fn a_new_mac_run_and_a_new_phone_boot_are_flagged() {
    let mut store = store();
    accepted(store.hello(&hello(), 1).unwrap());
    let mut restarted = store_with("mac-run-2", store.into_connection());
    let mut rebooted = hello();
    rebooted.device.boot_id = "66666666-6666-4666-8666-666666666666".into();
    accepted(restarted.hello(&rebooted, 2).unwrap());
    let conn = restarted.connection();
    let changed: String = conn
        .query_row(
            "SELECT severity FROM session_events WHERE kind = 'receiver_attached'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(changed, "warning");
    assert_eq!(mac_events(conn, "phone_clock_domain_changed"), 1);
}

#[test]
fn validate_reports_missing_bye_and_gaps() {
    let mut store = store();
    accepted(store.hello(&hello(), 1).unwrap());
    store.batch(&batch(0, 9), 2).unwrap();
    store.batch(&batch(15, 19), 3).unwrap();
    let report = sessions::validate(store.connection(), SESSION).unwrap();
    assert_eq!(report.devices[0].missing, vec![(10, 14)]);
    assert!(
        report
            .problems
            .iter()
            .any(|p| p.contains("10..=14 missing"))
    );
    assert!(report.problems.iter().any(|p| p.contains("no bye")));
    let gyro = report.devices[0]
        .streams
        .iter()
        .find(|s| s.stream == "gyro")
        .unwrap();
    assert_eq!(gyro.samples, 4);
    assert_eq!(gyro.non_increasing_timestamps, 0);
}

fn full_session(store: &mut Store) {
    accepted(store.hello(&hello(), 1).unwrap());
    store.phone_event(&event(), 2).unwrap();
    store.site(&site(), 2).unwrap();
    for first in (0..600).step_by(250) {
        store
            .batch(&batch(first, (first + 249).min(599)), 3)
            .unwrap();
    }
    store
        .marker(&marker("55555555-5555-4555-8555-555555555555"))
        .unwrap();
    store.clock_result(&clock_result(0, MAC_RUN_A)).unwrap();
    store.clock_result(&clock_result(1, MAC_RUN_A)).unwrap();
    store.bye(&bye(Some(599)), 4).unwrap();
}

fn clock_rows(conn: &Connection) -> Vec<Vec<rusqlite::types::Value>> {
    let mut stmt = conn
        .prepare("SELECT * FROM clock_sync ORDER BY session_id, device_id, exchange_index")
        .unwrap();
    stmt.query_map([], |r| (0..8).map(|i| r.get(i)).collect())
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

fn export_to_vec(conn: &Connection) -> (Vec<u8>, sessions::ExportSummary) {
    let mut out = Vec::new();
    let summary = sessions::export(conn, SESSION, &mut out).unwrap();
    (out, summary)
}

const SAMPLE_COLUMNS: &str = "SELECT seq, stream, source_phone_ns, q_w, q_x, q_y, q_z,
    rotation_rate_x, rotation_rate_y, rotation_rate_z, gravity_x, gravity_y, gravity_z,
    user_accel_x, user_accel_y, user_accel_z, accel_x, accel_y, accel_z,
    magnetic_field_x_ut, magnetic_field_y_ut, magnetic_field_z_ut, magnetic_accuracy
    FROM sensor_samples ORDER BY seq";

fn raw_rows(conn: &Connection) -> Vec<Vec<rusqlite::types::Value>> {
    let mut stmt = conn.prepare(SAMPLE_COLUMNS).unwrap();
    stmt.query_map([], |r| (0..23).map(|i| r.get(i)).collect())
        .unwrap()
        .collect::<Result<_, _>>()
        .unwrap()
}

#[test]
fn export_is_valid_protocol_and_imports_back_identically() {
    let mut original = store();
    full_session(&mut original);
    let (bytes, summary) = export_to_vec(original.connection());
    assert_eq!(summary.samples, 600);
    let text = String::from_utf8(bytes.clone()).unwrap();
    let messages: Vec<Message> = text
        .lines()
        .map(|line| {
            let value: serde_json::Value = serde_json::from_str(line).unwrap();
            cwb_protocol::schema::validate(&value).unwrap();
            serde_json::from_value(value).unwrap()
        })
        .collect();
    assert!(matches!(messages.first(), Some(Message::Hello(h)) if *h == hello()));
    assert!(matches!(messages.last(), Some(Message::Bye(b)) if *b == bye(Some(599))));
    assert_eq!(
        messages
            .iter()
            .filter(|m| matches!(m, Message::SampleBatch(_)))
            .count(),
        3
    );

    let mut copy = store_with("mac-run-2", open_in_memory().unwrap());
    let imported = sessions::import(&mut copy, &mut Cursor::new(&bytes), &|| 7).unwrap();
    assert!(imported.created);
    assert_eq!(imported.stored_samples, 600);
    assert!(imported.skipped.is_empty(), "{:?}", imported.skipped);
    assert_eq!(imported.clock_exchanges, 2);
    assert_eq!(imported.sites, 1);
    assert_eq!(
        sessions::stored_sites(copy.connection(), SESSION, DEVICE).unwrap(),
        [site()]
    );
    assert_eq!(raw_rows(original.connection()), raw_rows(copy.connection()));
    assert_eq!(
        clock_rows(original.connection()),
        clock_rows(copy.connection())
    );
    assert_eq!(status(copy.connection()), "ended");

    // Exporting the copy gives byte-identical output.
    let (again, again_summary) = export_to_vec(copy.connection());
    assert_eq!(again, bytes);
    assert_eq!(again_summary.sha256, summary.sha256);

    // Importing twice changes nothing.
    let twice = sessions::import(&mut copy, &mut Cursor::new(&bytes), &|| 8).unwrap();
    assert!(!twice.created);
    assert_eq!((twice.stored_samples, twice.duplicate_samples), (0, 600));
    assert_eq!(
        (twice.markers, twice.events, twice.clock_exchanges),
        (0, 0, 0)
    );
}

#[test]
fn clock_exchanges_are_stored_once_and_checked() {
    let mut store = store();
    assert!(matches!(
        store.clock_result(&clock_result(0, MAC_RUN_A)),
        Err(StorageError::UnknownSession(_))
    ));
    accepted(store.hello(&hello(), 1).unwrap());
    assert!(store.clock_result(&clock_result(0, MAC_RUN_A)).unwrap());
    assert!(!store.clock_result(&clock_result(0, MAC_RUN_A)).unwrap());

    // The same index with different times, or from another receiver run, conflicts.
    let mut changed = clock_result(0, MAC_RUN_A);
    changed.phone_receive_ns += 1;
    assert!(matches!(
        store.clock_result(&changed),
        Err(StorageError::InvalidMessage(_))
    ));
    assert!(matches!(
        store.clock_result(&clock_result(0, MAC_RUN_B)),
        Err(StorageError::InvalidMessage(_))
    ));

    // Time can't run backwards within one clock.
    let mut backwards = clock_result(1, MAC_RUN_A);
    backwards.phone_receive_ns = backwards.phone_send_ns - 1;
    assert!(matches!(
        store.clock_result(&backwards),
        Err(StorageError::InvalidMessage(_))
    ));
    assert_eq!(
        count(store.connection(), "SELECT COUNT(*) FROM clock_sync"),
        1
    );
}

#[test]
fn clock_models_are_fitted_per_receiver_run_and_stored() {
    let mut store = store();
    accepted(store.hello(&hello(), 1).unwrap());
    for i in 0..20 {
        store.clock_result(&clock_result(i, MAC_RUN_A)).unwrap();
    }
    for i in 20..25 {
        store.clock_result(&clock_result(i, MAC_RUN_B)).unwrap();
    }
    let models = clockfit::fit_session(store.connection(), SESSION).unwrap();
    assert_eq!(models.len(), 2);
    let (device, a) = &models[0];
    assert_eq!(device, DEVICE);
    assert_eq!(a.mac_clock_boot_id, MAC_RUN_A);
    assert_eq!(a.phone_boot_id.as_deref(), Some(BOOT));
    assert_eq!((a.exchanges, a.offset_ns), (20, 3_000_000_000));
    assert!(a.drift_fitted);
    assert!(a.drift_ppb.abs() < 1e-3);
    assert_eq!(a.uncertainty_ns, 1_000_000);
    let b = &models[1].1;
    assert_eq!((b.mac_clock_boot_id.as_str(), b.exchanges), (MAC_RUN_B, 5));
    assert!(!b.drift_fitted, "8 s is too short to fit drift");

    // validate reports a fresh fit; saving adds rows and keeps earlier ones.
    let report = sessions::validate(store.connection(), SESSION).unwrap();
    assert_eq!(report.clock, models);
    clockfit::store(store.connection(), SESSION, &models).unwrap();
    let ids = clockfit::store(store.connection(), SESSION, &models).unwrap();
    assert_eq!(ids.len(), 2);
    assert_eq!(
        count(store.connection(), "SELECT COUNT(*) FROM clock_models"),
        4
    );
}

#[test]
fn import_fills_in_what_the_network_missed() {
    let mut full = store();
    full_session(&mut full);
    let (log, _) = export_to_vec(full.connection());

    let mut live = store_with("mac-run-2", open_in_memory().unwrap());
    accepted(live.hello(&hello(), 1).unwrap());
    live.batch(&batch(0, 99), 2).unwrap();
    live.batch(&batch(300, 349), 2).unwrap();
    let summary = sessions::import(&mut live, &mut Cursor::new(&log), &|| 9).unwrap();
    assert_eq!(
        (summary.stored_samples, summary.duplicate_samples),
        (450, 150)
    );
    assert_eq!(raw_rows(full.connection()), raw_rows(live.connection()));
    let report = sessions::validate(live.connection(), SESSION).unwrap();
    assert!(report.problems.is_empty(), "{:?}", report.problems);
}

#[test]
fn import_skips_a_truncated_last_line() {
    let mut full = store();
    full_session(&mut full);
    let (mut log, _) = export_to_vec(full.connection());
    log.truncate(log.len() - 10);
    let mut copy = store_with("mac-run-2", open_in_memory().unwrap());
    let summary = sessions::import(&mut copy, &mut Cursor::new(&log), &|| 1).unwrap();
    assert_eq!(summary.skipped.len(), 1);
    assert!(summary.skipped[0].contains("truncated"));
    assert_eq!(summary.stored_samples, 600);
}

#[test]
fn session_ids_resolve_from_unique_prefixes() {
    let mut store = store();
    accepted(store.hello(&hello(), 1).unwrap());
    let conn = store.connection();
    assert_eq!(sessions::resolve(conn, "1111").unwrap(), SESSION);
    assert!(matches!(
        sessions::resolve(conn, "9999"),
        Err(StorageError::UnknownSession(_))
    ));
}
