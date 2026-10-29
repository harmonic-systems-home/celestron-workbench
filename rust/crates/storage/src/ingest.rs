//! Storing protocol messages (ADR 0003, ADR 0006).
//!
//! [`Store`] owns the write connection. The receiver runs exactly one, on the
//! database writer thread; `cwb session import` runs one directly. Raw rows are
//! only ever inserted: duplicates are skipped and counted, conflicting
//! duplicates are flagged, and nothing is interpolated.

use std::collections::{HashMap, HashSet};

use cwb_protocol::{
    Bye, ErrorCode, Event, Hello, Marker, Nanos, PROTOCOL_VERSION, Sample, SampleBatch, Seq,
};
use rusqlite::{
    Connection, OptionalExtension, Transaction, params, params_from_iter, types::Value,
};
use serde_json::json;

use crate::{SCHEMA_VERSION, StorageError, clock::utc_now};

/// What a `Store` writes into new sessions.
#[derive(Debug, Clone)]
pub struct StoreConfig {
    /// The Mac clock domain that `receive_mac_ns` values belong to.
    pub mac_clock_boot_id: String,
    /// JSON object: component -> version.
    pub software_versions: serde_json::Value,
}

/// The answer to a `hello`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HelloOutcome {
    Accepted {
        created: bool,
        highest_contiguous_seq: Option<Seq>,
    },
    Rejected {
        code: ErrorCode,
        reason: String,
    },
}

/// What happened to one sample batch.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct BatchOutcome {
    pub stored: usize,
    /// Samples already stored with the same stream and timestamp (resends).
    pub duplicates: usize,
    /// Samples whose seq is already stored with different contents.
    pub conflicts: usize,
    /// `Some((expected, first_seq))` when the batch starts past the next expected seq.
    pub gap: Option<(Seq, Seq)>,
    pub highest_contiguous_seq: Option<Seq>,
}

/// What happened to a `bye`.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ByeOutcome {
    pub highest_contiguous_seq: Option<Seq>,
    /// True when every sample up to the phone's `last_seq` is stored.
    pub complete: bool,
}

#[derive(Debug, Clone, Copy, Default)]
struct Progress {
    contiguous: Option<Seq>,
    max_seen: Option<Seq>,
}

type DeviceKey = (String, String);

pub struct Store {
    conn: Connection,
    config: StoreConfig,
    progress: HashMap<DeviceKey, Progress>,
    /// Sessions this store has seen, so domain changes are noted once per run.
    attached: HashSet<String>,
}

impl Store {
    pub fn new(conn: Connection, config: StoreConfig) -> Self {
        Self {
            conn,
            config,
            progress: HashMap::new(),
            attached: HashSet::new(),
        }
    }

    pub fn connection(&self) -> &Connection {
        &self.conn
    }

    pub fn into_connection(self) -> Connection {
        self.conn
    }

    /// Creates the session on first contact, or accepts a reconnect.
    pub fn hello(
        &mut self,
        hello: &Hello,
        receive_mac_ns: Nanos,
    ) -> Result<HelloOutcome, StorageError> {
        if hello.protocol_version != PROTOCOL_VERSION {
            return Ok(HelloOutcome::Rejected {
                code: ErrorCode::UnsupportedVersion,
                reason: format!(
                    "protocol version {} is not supported (expected {PROTOCOL_VERSION})",
                    hello.protocol_version
                ),
            });
        }
        let session = hello.session_id.as_str();
        let device = hello.device.device_id.as_str();
        let tx = self.conn.transaction()?;
        let existing: Option<(String, String)> = tx
            .query_row(
                "SELECT status, mac_clock_boot_id FROM sessions WHERE session_id = ?1",
                [session],
                |r| Ok((r.get(0)?, r.get(1)?)),
            )
            .optional()?;
        let created = match existing {
            None => {
                create_session(&tx, &self.config, hello)?;
                insert_mac_event(
                    &tx,
                    session,
                    Some(device),
                    "session_created",
                    "info",
                    json!({ "mac_clock_boot_id": self.config.mac_clock_boot_id }),
                    receive_mac_ns,
                )?;
                true
            }
            Some((status, session_boot_id)) => {
                let phone: Option<Option<String>> = tx
                    .query_row(
                        "SELECT phone_boot_id FROM devices WHERE session_id = ?1 AND device_id = ?2",
                        [session, device],
                        |r| r.get(0),
                    )
                    .optional()?;
                let Some(phone_boot_id) = phone else {
                    return Ok(HelloOutcome::Rejected {
                        code: ErrorCode::DeviceMismatch,
                        reason: format!("session {session} belongs to another device"),
                    });
                };
                if status == "incomplete" {
                    tx.execute(
                        "UPDATE sessions SET status = 'recording', status_reason = NULL WHERE session_id = ?1",
                        [session],
                    )?;
                }
                if !self.attached.contains(session) {
                    let changed = session_boot_id != self.config.mac_clock_boot_id;
                    insert_mac_event(
                        &tx,
                        session,
                        Some(device),
                        "receiver_attached",
                        if changed { "warning" } else { "info" },
                        json!({
                            "mac_clock_boot_id": self.config.mac_clock_boot_id,
                            "mac_clock_domain_changed": changed,
                        }),
                        receive_mac_ns,
                    )?;
                }
                if phone_boot_id.as_deref() != Some(hello.device.boot_id.as_str()) {
                    insert_mac_event(
                        &tx,
                        session,
                        Some(device),
                        "phone_clock_domain_changed",
                        "warning",
                        json!({ "from": phone_boot_id, "to": hello.device.boot_id }),
                        receive_mac_ns,
                    )?;
                }
                insert_mac_event(
                    &tx,
                    session,
                    Some(device),
                    "reconnected",
                    "info",
                    json!({ "status_before": status }),
                    receive_mac_ns,
                )?;
                false
            }
        };
        tx.commit()?;
        self.attached.insert(session.to_owned());
        let progress = self.progress(session, device)?;
        Ok(HelloOutcome::Accepted {
            created,
            highest_contiguous_seq: progress.contiguous,
        })
    }

    /// Stores a batch. The caller acknowledges `highest_contiguous_seq` only
    /// after this returns, so acknowledgements always mean "durably stored".
    pub fn batch(
        &mut self,
        batch: &SampleBatch,
        receive_mac_ns: Nanos,
    ) -> Result<BatchOutcome, StorageError> {
        batch
            .check_contiguous()
            .map_err(StorageError::InvalidMessage)?;
        let session = batch.session_id.as_str();
        let device = batch.device_id.as_str();
        let before = self.progress(session, device)?;
        let tx = self.conn.transaction()?;

        let mut existing: HashMap<Seq, (String, Nanos)> = HashMap::new();
        {
            let mut stmt = tx.prepare_cached(
                "SELECT seq, stream, source_phone_ns FROM sensor_samples
                 WHERE session_id = ?1 AND device_id = ?2 AND seq BETWEEN ?3 AND ?4",
            )?;
            let rows = stmt.query_map(
                params![
                    session,
                    device,
                    seq_sql(batch.first_seq),
                    seq_sql(batch.last_seq)
                ],
                |r| Ok((r.get::<_, i64>(0)?, r.get(1)?, r.get(2)?)),
            )?;
            for row in rows {
                let (seq, stream, t) = row?;
                existing.insert(seq as Seq, (stream, t));
            }
        }

        let mut outcome = BatchOutcome::default();
        let mut conflicting: Vec<Seq> = Vec::new();
        {
            let mut insert = tx.prepare_cached(INSERT_SAMPLE)?;
            for sample in &batch.samples {
                let row = SampleRow::from(sample);
                if let Some((stream, t)) = existing.get(&sample.seq()) {
                    if stream == row.stream && *t == sample.t_ns() {
                        outcome.duplicates += 1;
                    } else {
                        conflicting.push(sample.seq());
                    }
                    continue;
                }
                insert.execute(params_from_iter(row.values(
                    session,
                    device,
                    sample.seq(),
                    receive_mac_ns,
                )))?;
                outcome.stored += 1;
            }
        }
        outcome.conflicts = conflicting.len();

        let expected = before.max_seen.map_or(0, |m| m + 1);
        if batch.first_seq > expected {
            outcome.gap = Some((expected, batch.first_seq));
            insert_mac_event(
                &tx,
                session,
                Some(device),
                "sequence_gap",
                "warning",
                json!({
                    "expected_seq": expected,
                    "first_seq": batch.first_seq,
                    "missing": batch.first_seq - expected,
                }),
                receive_mac_ns,
            )?;
        }
        if outcome.duplicates > 0 {
            insert_mac_event(
                &tx,
                session,
                Some(device),
                "duplicate_samples",
                "info",
                json!({
                    "first_seq": batch.first_seq,
                    "last_seq": batch.last_seq,
                    "count": outcome.duplicates,
                }),
                receive_mac_ns,
            )?;
        }
        if !conflicting.is_empty() {
            insert_mac_event(
                &tx,
                session,
                Some(device),
                "conflicting_samples",
                "error",
                json!({
                    "count": conflicting.len(),
                    "seqs": conflicting.iter().take(20).collect::<Vec<_>>(),
                }),
                receive_mac_ns,
            )?;
        }
        let contiguous = advance_contiguous(&tx, session, device, before.contiguous)?;
        tx.commit()?;

        let progress = Progress {
            contiguous,
            max_seen: Some(
                before
                    .max_seen
                    .map_or(batch.last_seq, |m| m.max(batch.last_seq)),
            ),
        };
        self.progress
            .insert((session.to_owned(), device.to_owned()), progress);
        outcome.highest_contiguous_seq = contiguous;
        Ok(outcome)
    }

    /// Stores a phone marker. Returns false if it was already stored.
    pub fn marker(&mut self, marker: &Marker) -> Result<bool, StorageError> {
        self.require_device(&marker.session_id, &marker.device_id)?;
        let inserted = self.conn.execute(
            "INSERT INTO markers (marker_id, session_id, source, label, source_ns, source_clock, notes)
             VALUES (?1, ?2, 'phone', ?3, ?4, 'phone', ?5)
             ON CONFLICT (marker_id) DO NOTHING",
            params![
                marker.marker_id,
                marker.session_id,
                marker.label,
                marker.t_ns,
                marker.notes
            ],
        )?;
        Ok(inserted == 1)
    }

    /// Stores a phone event. Returns false if an identical one was already stored.
    pub fn phone_event(
        &mut self,
        event: &Event,
        receive_mac_ns: Nanos,
    ) -> Result<bool, StorageError> {
        self.require_device(&event.session_id, &event.device_id)?;
        let kind = enum_str(&event.kind);
        let severity = enum_str(&event.severity);
        let detail = serde_json::to_string(&event.detail)?;
        let exists: bool = self.conn.query_row(
            "SELECT EXISTS (SELECT 1 FROM session_events
             WHERE session_id = ?1 AND device_id = ?2 AND source = 'phone'
               AND kind = ?3 AND source_ns = ?4 AND detail = ?5)",
            params![event.session_id, event.device_id, kind, event.t_ns, detail],
            |r| r.get(0),
        )?;
        if exists {
            return Ok(false);
        }
        self.conn.execute(
            "INSERT INTO session_events
             (session_id, device_id, source, kind, severity, source_ns, receive_mac_ns, detail)
             VALUES (?1, ?2, 'phone', ?3, ?4, ?5, ?6, ?7)",
            params![
                event.session_id,
                event.device_id,
                kind,
                severity,
                event.t_ns,
                receive_mac_ns,
                detail
            ],
        )?;
        Ok(true)
    }

    /// Records a Mac-side event (connections, rejected messages, imports).
    pub fn mac_event(
        &mut self,
        session_id: &str,
        device_id: Option<&str>,
        kind: &str,
        severity: &str,
        detail: serde_json::Value,
        receive_mac_ns: Nanos,
    ) -> Result<(), StorageError> {
        insert_mac_event(
            &self.conn,
            session_id,
            device_id,
            kind,
            severity,
            detail,
            receive_mac_ns,
        )
    }

    /// Ends the session. It is `ended` if everything up to the phone's
    /// `last_seq` is stored, otherwise `incomplete`. Analyst decisions
    /// (`accepted`, `rejected`) are never overwritten.
    pub fn bye(&mut self, bye: &Bye, receive_mac_ns: Nanos) -> Result<ByeOutcome, StorageError> {
        self.require_device(&bye.session_id, &bye.device_id)?;
        let progress = self.progress(&bye.session_id, &bye.device_id)?;
        let complete = match bye.last_seq {
            None => true,
            Some(last) => progress.contiguous.is_some_and(|c| c >= last),
        };
        let reason = (!complete).then(|| {
            format!(
                "phone sent up to seq {:?}; stored contiguously up to {:?}",
                bye.last_seq, progress.contiguous
            )
        });
        let tx = self.conn.transaction()?;
        insert_mac_event(
            &tx,
            &bye.session_id,
            Some(&bye.device_id),
            "bye",
            if complete { "info" } else { "warning" },
            json!({
                "reason": bye.reason,
                "last_seq": bye.last_seq,
                "highest_contiguous_seq": progress.contiguous,
            }),
            receive_mac_ns,
        )?;
        tx.execute(
            "UPDATE sessions
             SET status = ?2, status_reason = ?3, ended_utc = COALESCE(ended_utc, ?4)
             WHERE session_id = ?1 AND status IN ('recording', 'ended', 'incomplete')",
            params![
                bye.session_id,
                if complete { "ended" } else { "incomplete" },
                reason,
                utc_now()
            ],
        )?;
        tx.commit()?;
        Ok(ByeOutcome {
            highest_contiguous_seq: progress.contiguous,
            complete,
        })
    }

    /// Marks a session that is still recording as incomplete, e.g. when the
    /// receiver shuts down or the operator closes it before `bye` arrives.
    /// Returns false if the session was not recording.
    pub fn mark_incomplete(
        &mut self,
        session_id: &str,
        reason: &str,
    ) -> Result<bool, StorageError> {
        let changed = self.conn.execute(
            "UPDATE sessions SET status = 'incomplete', status_reason = ?2
             WHERE session_id = ?1 AND status = 'recording'",
            params![session_id, reason],
        )?;
        Ok(changed == 1)
    }

    /// The highest seq up to which every sample is stored.
    pub fn highest_contiguous_seq(
        &mut self,
        session_id: &str,
        device_id: &str,
    ) -> Result<Option<Seq>, StorageError> {
        Ok(self.progress(session_id, device_id)?.contiguous)
    }

    /// Checkpoints the WAL (ADR 0003).
    pub fn checkpoint(&self) -> Result<(), StorageError> {
        crate::checkpoint(&self.conn)
    }

    fn require_device(&mut self, session_id: &str, device_id: &str) -> Result<(), StorageError> {
        self.progress(session_id, device_id).map(|_| ())
    }

    fn progress(&mut self, session_id: &str, device_id: &str) -> Result<Progress, StorageError> {
        let key = (session_id.to_owned(), device_id.to_owned());
        if let Some(p) = self.progress.get(&key) {
            return Ok(*p);
        }
        let known: bool = self.conn.query_row(
            "SELECT EXISTS (SELECT 1 FROM devices WHERE session_id = ?1 AND device_id = ?2)",
            [session_id, device_id],
            |r| r.get(0),
        )?;
        if !known {
            return Err(StorageError::UnknownSession(session_id.to_owned()));
        }
        let max_seen: Option<i64> = self.conn.query_row(
            "SELECT MAX(seq) FROM sensor_samples WHERE session_id = ?1 AND device_id = ?2",
            [session_id, device_id],
            |r| r.get(0),
        )?;
        let progress = Progress {
            contiguous: advance_contiguous(&self.conn, session_id, device_id, None)?,
            max_seen: max_seen.map(|m| m as Seq),
        };
        self.progress.insert(key, progress);
        Ok(progress)
    }
}

fn create_session(
    tx: &Transaction<'_>,
    config: &StoreConfig,
    hello: &Hello,
) -> Result<(), StorageError> {
    tx.execute(
        "INSERT INTO sessions
         (session_id, created_utc, phase, status, schema_version, software_versions, mac_clock_boot_id)
         VALUES (?1, ?2, 'bench', 'recording', ?3, ?4, ?5)",
        params![
            hello.session_id,
            utc_now(),
            SCHEMA_VERSION,
            config.software_versions.to_string(),
            config.mac_clock_boot_id
        ],
    )?;
    tx.execute(
        "INSERT INTO devices
         (session_id, device_id, role, vendor, model, os_or_firmware, app_version, phone_boot_id,
          sensor_availability, attitude_reference_frame, requested_interval_s, accel_g0_m_s2, streams)
         VALUES (?1, ?2, 'imu_phone', ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![
            hello.session_id,
            hello.device.device_id,
            hello.device.vendor,
            hello.device.model,
            hello.device.os_version,
            hello.device.app_version,
            hello.device.boot_id,
            serde_json::to_string(&hello.sensor_availability)?,
            enum_str(&hello.attitude_reference_frame),
            hello.requested_interval_s,
            hello.accel_g0_m_s2,
            serde_json::to_string(&hello.streams)?,
        ],
    )?;
    Ok(())
}

fn insert_mac_event(
    conn: &Connection,
    session_id: &str,
    device_id: Option<&str>,
    kind: &str,
    severity: &str,
    detail: serde_json::Value,
    receive_mac_ns: Nanos,
) -> Result<(), StorageError> {
    conn.execute(
        "INSERT INTO session_events
         (session_id, device_id, source, kind, severity, source_ns, receive_mac_ns, detail)
         VALUES (?1, ?2, 'mac', ?3, ?4, ?5, ?5, ?6)",
        params![
            session_id,
            device_id,
            kind,
            severity,
            receive_mac_ns,
            detail.to_string()
        ],
    )?;
    Ok(())
}

/// Walks forward from `from` while the next seq is stored. Rows past a gap
/// stop the walk at once, so this stays cheap while a gap is open.
fn advance_contiguous(
    conn: &Connection,
    session_id: &str,
    device_id: &str,
    from: Option<Seq>,
) -> Result<Option<Seq>, StorageError> {
    let mut next = from.map_or(0, |c| c + 1);
    let mut contiguous = from;
    let mut stmt = conn.prepare_cached(
        "SELECT seq FROM sensor_samples
         WHERE session_id = ?1 AND device_id = ?2 AND seq >= ?3 ORDER BY seq",
    )?;
    let mut rows = stmt.query(params![session_id, device_id, seq_sql(next)])?;
    while let Some(row) = rows.next()? {
        if row.get::<_, i64>(0)? as Seq != next {
            break;
        }
        contiguous = Some(next);
        next += 1;
    }
    Ok(contiguous)
}

fn seq_sql(seq: Seq) -> i64 {
    i64::try_from(seq).unwrap_or(i64::MAX)
}

/// The JSON string form of a unit enum, e.g. `x_arbitrary_z_vertical`.
pub(crate) fn enum_str<T: serde::Serialize>(value: &T) -> String {
    match serde_json::to_value(value) {
        Ok(serde_json::Value::String(s)) => s,
        other => panic!("expected a string enum, got {other:?}"),
    }
}

const INSERT_SAMPLE: &str = "INSERT INTO sensor_samples (
    session_id, device_id, seq, stream, source_phone_ns, receive_mac_ns,
    q_w, q_x, q_y, q_z,
    rotation_rate_x, rotation_rate_y, rotation_rate_z,
    gravity_x, gravity_y, gravity_z,
    user_accel_x, user_accel_y, user_accel_z,
    accel_x, accel_y, accel_z,
    magnetic_field_x_ut, magnetic_field_y_ut, magnetic_field_z_ut,
    magnetic_accuracy
) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?17, ?18,
          ?19, ?20, ?21, ?22, ?23, ?24, ?25, ?26)";

/// A sample flattened into `sensor_samples` columns. Absent values are NULL.
#[derive(Default)]
struct SampleRow {
    stream: &'static str,
    t_ns: Nanos,
    quaternion: Option<[f64; 4]>,
    rotation_rate: Option<[f64; 3]>,
    gravity: Option<[f64; 3]>,
    user_accel: Option<[f64; 3]>,
    accel: Option<[f64; 3]>,
    magnetic_field: Option<[f64; 3]>,
    magnetic_accuracy: Option<String>,
}

impl From<&Sample> for SampleRow {
    fn from(sample: &Sample) -> Self {
        match sample {
            Sample::DeviceMotion(s) => SampleRow {
                stream: "device_motion",
                t_ns: s.t_ns,
                quaternion: Some([s.attitude.w, s.attitude.x, s.attitude.y, s.attitude.z]),
                rotation_rate: Some(s.rotation_rate),
                gravity: Some(s.gravity),
                user_accel: Some(s.user_accel),
                magnetic_field: s.magnetic_field_ut,
                magnetic_accuracy: s.magnetic_accuracy.as_ref().map(enum_str),
                ..Default::default()
            },
            Sample::Gyro(s) => SampleRow {
                stream: "gyro",
                t_ns: s.t_ns,
                rotation_rate: Some(s.rotation_rate),
                ..Default::default()
            },
            Sample::Accel(s) => SampleRow {
                stream: "accel",
                t_ns: s.t_ns,
                accel: Some(s.accel),
                ..Default::default()
            },
            Sample::Magnetometer(s) => SampleRow {
                stream: "magnetometer",
                t_ns: s.t_ns,
                magnetic_field: Some(s.magnetic_field_ut),
                ..Default::default()
            },
        }
    }
}

impl SampleRow {
    fn values(
        self,
        session_id: &str,
        device_id: &str,
        seq: Seq,
        receive_mac_ns: Nanos,
    ) -> Vec<Value> {
        fn reals<const N: usize>(out: &mut Vec<Value>, v: Option<[f64; N]>) {
            match v {
                Some(v) => out.extend(v.map(Value::Real)),
                None => out.extend(std::iter::repeat_n(Value::Null, N)),
            }
        }
        let mut out = vec![
            Value::Text(session_id.to_owned()),
            Value::Text(device_id.to_owned()),
            Value::Integer(seq_sql(seq)),
            Value::Text(self.stream.to_owned()),
            Value::Integer(self.t_ns),
            Value::Integer(receive_mac_ns),
        ];
        reals(&mut out, self.quaternion);
        reals(&mut out, self.rotation_rate);
        reals(&mut out, self.gravity);
        reals(&mut out, self.user_accel);
        reals(&mut out, self.accel);
        reals(&mut out, self.magnetic_field);
        out.push(self.magnetic_accuracy.map_or(Value::Null, Value::Text));
        out
    }
}
