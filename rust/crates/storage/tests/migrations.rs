use std::{fs, path::PathBuf};

use cwb_storage::{MIGRATIONS, SCHEMA_VERSION, migrate, open_in_memory, schema_version};
use rusqlite::{Connection, params};

const SESSION: &str = "11111111-1111-4111-8111-111111111111";
const DEVICE: &str = "22222222-2222-4222-8222-222222222222";

fn table_names(conn: &Connection) -> Vec<String> {
    let mut stmt = conn
        .prepare("SELECT name FROM sqlite_schema WHERE type = 'table' ORDER BY name")
        .unwrap();
    stmt.query_map([], |r| r.get(0))
        .unwrap()
        .map(Result::unwrap)
        .collect()
}

/// A database with one session, one phone and one sample.
fn seeded() -> Connection {
    let conn = open_in_memory().unwrap();
    conn.execute(
        "INSERT INTO sessions (session_id, created_utc, phase, schema_version, software_versions, mac_clock_boot_id)
         VALUES (?1, '2026-10-28T00:00:00Z', 'bench', ?2, '{}', 'boot-a')",
        params![SESSION, SCHEMA_VERSION],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO devices (session_id, device_id, role) VALUES (?1, ?2, 'imu_phone')",
        params![SESSION, DEVICE],
    )
    .unwrap();
    conn.execute(
        "INSERT INTO sensor_samples (session_id, device_id, seq, stream, source_phone_ns, receive_mac_ns,
                                     q_w, q_x, q_y, q_z)
         VALUES (?1, ?2, 0, 'device_motion', 1000, 2000, 1.0, 0.0, 0.0, 0.0)",
        params![SESSION, DEVICE],
    )
    .unwrap();
    conn
}

#[test]
fn migration_files_match_the_embedded_list() {
    let dir = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../schemas/sql");
    let mut files: Vec<String> = fs::read_dir(&dir)
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|n| n.ends_with(".sql"))
        .map(|n| n.trim_end_matches(".sql").to_owned())
        .collect();
    files.sort();
    let embedded: Vec<&str> = MIGRATIONS.iter().map(|m| m.name).collect();
    assert_eq!(
        files, embedded,
        "every file in schemas/sql must be listed in MIGRATIONS"
    );
    for (i, m) in MIGRATIONS.iter().enumerate() {
        assert_eq!(
            m.version as usize,
            i + 1,
            "versions must be contiguous from 1"
        );
        assert!(m.name.starts_with(&format!("{:04}_", m.version)));
    }
}

#[test]
fn migrates_empty_database_to_current_version() {
    let conn = open_in_memory().unwrap();
    assert_eq!(schema_version(&conn).unwrap(), SCHEMA_VERSION);
    let tables = table_names(&conn);
    for expected in [
        "artifacts",
        "attachments",
        "clock_models",
        "clock_sync",
        "commands",
        "configs",
        "derived_results",
        "devices",
        "markers",
        "mount_events",
        "sample_alignment",
        "sensor_samples",
        "session_events",
        "sessions",
    ] {
        assert!(
            tables.iter().any(|t| t == expected),
            "missing table {expected}"
        );
    }
}

#[test]
fn migrating_twice_is_a_no_op() {
    let mut conn = open_in_memory().unwrap();
    assert!(migrate(&mut conn).unwrap().is_empty());
}

#[test]
fn refuses_a_database_from_newer_software() {
    let mut conn = Connection::open_in_memory().unwrap();
    conn.pragma_update(None, "user_version", SCHEMA_VERSION + 1)
        .unwrap();
    assert!(migrate(&mut conn).is_err());
}

#[test]
fn schema_passes_integrity_and_foreign_key_checks() {
    let conn = seeded();
    let ok: String = conn
        .query_row("PRAGMA integrity_check", [], |r| r.get(0))
        .unwrap();
    assert_eq!(ok, "ok");
    let violations: i64 = conn
        .query_row("SELECT count(*) FROM pragma_foreign_key_check", [], |r| {
            r.get(0)
        })
        .unwrap();
    assert_eq!(violations, 0);
}

#[test]
fn foreign_keys_are_enforced() {
    let conn = seeded();
    let err = conn.execute(
        "INSERT INTO sensor_samples (session_id, device_id, seq, stream, source_phone_ns, receive_mac_ns)
         VALUES (?1, 'not-a-device', 1, 'gyro', 1, 1)",
        params![SESSION],
    );
    assert!(err.is_err());
}

#[test]
fn raw_tables_are_append_only() {
    let conn = seeded();
    assert!(
        conn.execute("UPDATE sensor_samples SET q_w = 0.5", [])
            .is_err()
    );
    assert!(conn.execute("DELETE FROM sensor_samples", []).is_err());
    let count: i64 = conn
        .query_row("SELECT count(*) FROM sensor_samples", [], |r| r.get(0))
        .unwrap();
    assert_eq!(count, 1);
}

#[test]
fn duplicate_sequence_numbers_are_rejected() {
    let conn = seeded();
    let err = conn.execute(
        "INSERT INTO sensor_samples (session_id, device_id, seq, stream, source_phone_ns, receive_mac_ns)
         VALUES (?1, ?2, 0, 'gyro', 1, 1)",
        params![SESSION, DEVICE],
    );
    assert!(err.is_err());
}

#[test]
fn strict_tables_reject_wrong_types() {
    let conn = seeded();
    let err = conn.execute(
        "INSERT INTO sensor_samples (session_id, device_id, seq, stream, source_phone_ns, receive_mac_ns)
         VALUES (?1, ?2, 1, 'gyro', 'not a number', 1)",
        params![SESSION, DEVICE],
    );
    assert!(err.is_err());
}

#[test]
fn check_constraints_reject_unknown_enum_values() {
    let conn = seeded();
    let err = conn.execute(
        "INSERT INTO sensor_samples (session_id, device_id, seq, stream, source_phone_ns, receive_mac_ns)
         VALUES (?1, ?2, 1, 'barometer', 1, 1)",
        params![SESSION, DEVICE],
    );
    assert!(err.is_err());
}

#[test]
fn file_database_uses_wal_and_checkpoints() {
    let dir = std::env::temp_dir().join(format!("cwb-storage-test-{}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    let path = dir.join("test.sqlite");
    let _ = fs::remove_file(&path);
    let (conn, applied) = cwb_storage::open(&path).unwrap();
    assert_eq!(applied.last(), Some(&SCHEMA_VERSION));
    let mode: String = conn
        .query_row("PRAGMA journal_mode", [], |r| r.get(0))
        .unwrap();
    assert_eq!(mode, "wal");
    cwb_storage::checkpoint(&conn).unwrap();
    drop(conn);
    let ro = cwb_storage::open_read_only(&path).unwrap();
    assert_eq!(schema_version(&ro).unwrap(), SCHEMA_VERSION);
    drop(ro);
    let (_, applied) = cwb_storage::open(&path).unwrap();
    assert!(applied.is_empty());
    fs::remove_dir_all(&dir).unwrap();
}
