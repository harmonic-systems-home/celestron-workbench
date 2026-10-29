//! Session commands that work on stored data: list, validate, export, import.

use std::io::{BufRead, Write};

use cwb_protocol::{
    AccelSample, Bye, ByeReason, ClockResult, DeviceInfo, DeviceMotionSample, Event, GyroSample,
    Hello, Location, MagnetometerSample, Marker, Message, Nanos, PROTOCOL_VERSION, Quaternion,
    Sample, SampleBatch, Seq, Site,
};
use rusqlite::{Connection, OptionalExtension, Row, params};
use serde::Serialize;
use sha2::{Digest, Sha256};

use crate::{
    StorageError,
    clockfit::{self, ClockModel},
    ingest::{HelloOutcome, Store},
};

/// Samples per exported batch, matching the phone.
pub const EXPORT_BATCH_SAMPLES: usize = 250;

#[derive(Debug, Clone, Serialize)]
pub struct SessionSummary {
    pub session_id: String,
    pub created_utc: String,
    pub ended_utc: Option<String>,
    pub status: String,
    pub status_reason: Option<String>,
    pub samples: u64,
    pub markers: u64,
    /// As the phone reported it; `None` before sessions carried a site.
    pub environment: Option<String>,
}

pub fn list(conn: &Connection) -> Result<Vec<SessionSummary>, StorageError> {
    let mut stmt = conn.prepare(
        "SELECT s.session_id, s.created_utc, s.ended_utc, s.status, s.status_reason,
                (SELECT COUNT(*) FROM sensor_samples x WHERE x.session_id = s.session_id),
                (SELECT COUNT(*) FROM markers m WHERE m.session_id = s.session_id),
                (SELECT environment FROM session_sites w WHERE w.session_id = s.session_id
                 ORDER BY source_ns DESC, receive_mac_ns DESC LIMIT 1)
         FROM sessions s ORDER BY s.created_utc",
    )?;
    let rows = stmt.query_map([], |r| {
        Ok(SessionSummary {
            session_id: r.get(0)?,
            created_utc: r.get(1)?,
            ended_utc: r.get(2)?,
            status: r.get(3)?,
            status_reason: r.get(4)?,
            samples: r.get::<_, i64>(5)? as u64,
            markers: r.get::<_, i64>(6)? as u64,
            environment: r.get(7)?,
        })
    })?;
    Ok(rows.collect::<Result<_, _>>()?)
}

/// Resolves a full session ID from a unique prefix.
pub fn resolve(conn: &Connection, prefix: &str) -> Result<String, StorageError> {
    let mut stmt = conn
        .prepare("SELECT session_id FROM sessions WHERE substr(session_id, 1, ?2) = ?1 LIMIT 2")?;
    let matches: Vec<String> = stmt
        .query_map(params![prefix, prefix.len() as i64], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    match matches.as_slice() {
        [one] => Ok(one.clone()),
        [] => Err(StorageError::UnknownSession(prefix.to_owned())),
        _ => Err(StorageError::Ambiguous(prefix.to_owned())),
    }
}

#[derive(Debug, Clone, Serialize)]
pub struct StreamReport {
    pub stream: String,
    pub samples: u64,
    pub first_t_ns: Nanos,
    pub last_t_ns: Nanos,
    /// Mean delivered rate from phone timestamps.
    pub rate_hz: Option<f64>,
    pub min_interval_ns: Option<Nanos>,
    pub max_interval_ns: Option<Nanos>,
    /// Consecutive samples (in seq order) whose timestamp did not increase.
    pub non_increasing_timestamps: u64,
}

#[derive(Debug, Clone, Serialize)]
pub struct DeviceReport {
    pub device_id: String,
    pub samples: u64,
    pub first_seq: Option<Seq>,
    pub last_seq: Option<Seq>,
    /// Inclusive seq ranges that are missing between `first_seq` and `last_seq`.
    pub missing: Vec<(Seq, Seq)>,
    /// The phone's `last_seq` from `bye`, if one arrived.
    pub bye_last_seq: Option<Option<Seq>>,
    /// Samples the phone reported dropping before they got a seq (ADR 0006).
    pub dropped_on_phone: u64,
    pub streams: Vec<StreamReport>,
}

#[derive(Debug, Clone, Serialize)]
pub struct SessionReport {
    pub session: SessionSummary,
    pub devices: Vec<DeviceReport>,
    /// Count of events by `source:kind`.
    pub events: Vec<(String, u64)>,
    /// A fresh clock fit per device and Mac clock domain (not stored).
    pub clock: Vec<(String, ClockModel)>,
    /// Anything that makes the session's data incomplete or suspect.
    pub problems: Vec<String>,
}

/// Checks a stored session: sequence coverage, timestamps, bye, ingest problems.
pub fn validate(conn: &Connection, session_id: &str) -> Result<SessionReport, StorageError> {
    let session = list(conn)?
        .into_iter()
        .find(|s| s.session_id == session_id)
        .ok_or_else(|| StorageError::UnknownSession(session_id.to_owned()))?;
    let mut problems = Vec::new();
    let mut devices = Vec::new();
    for device_id in device_ids(conn, session_id)? {
        let report = device_report(conn, session_id, &device_id)?;
        if report.samples == 0 {
            problems.push(format!("device {}: no samples", short(&device_id)));
        }
        if report.first_seq.is_some_and(|f| f != 0) {
            problems.push(format!(
                "device {}: samples start at seq {}, not 0",
                short(&device_id),
                report.first_seq.unwrap_or_default()
            ));
        }
        for (a, b) in &report.missing {
            problems.push(format!(
                "device {}: seq {a}..={b} missing",
                short(&device_id)
            ));
        }
        match report.bye_last_seq {
            None => problems.push(format!("device {}: no bye received", short(&device_id))),
            Some(last) if last != report.last_seq => problems.push(format!(
                "device {}: bye says last seq {last:?}, stored up to {:?}",
                short(&device_id),
                report.last_seq
            )),
            Some(_) => {}
        }
        for s in &report.streams {
            if s.non_increasing_timestamps > 0 {
                problems.push(format!(
                    "device {}: {} {} timestamps did not increase",
                    short(&device_id),
                    s.non_increasing_timestamps,
                    s.stream
                ));
            }
        }
        devices.push(report);
    }
    let mut stmt = conn.prepare(
        "SELECT source || ':' || kind, COUNT(*) FROM session_events
         WHERE session_id = ?1 GROUP BY 1 ORDER BY 1",
    )?;
    let events: Vec<(String, u64)> = stmt
        .query_map([session_id], |r| {
            Ok((r.get(0)?, r.get::<_, i64>(1)? as u64))
        })?
        .collect::<Result<_, _>>()?;
    for (kind, count) in &events {
        if kind == "mac:conflicting_samples" {
            problems.push(format!(
                "{count} batch(es) carried samples that conflict with stored ones"
            ));
        }
    }
    let clock = clockfit::fit_session(conn, session_id)?;
    Ok(SessionReport {
        session,
        devices,
        events,
        clock,
        problems,
    })
}

fn device_ids(conn: &Connection, session_id: &str) -> Result<Vec<String>, StorageError> {
    let mut stmt =
        conn.prepare("SELECT device_id FROM devices WHERE session_id = ?1 ORDER BY device_id")?;
    let ids = stmt
        .query_map([session_id], |r| r.get(0))?
        .collect::<Result<_, _>>()?;
    Ok(ids)
}

fn device_report(
    conn: &Connection,
    session_id: &str,
    device_id: &str,
) -> Result<DeviceReport, StorageError> {
    let (samples, first, last): (i64, Option<i64>, Option<i64>) = conn.query_row(
        "SELECT COUNT(*), MIN(seq), MAX(seq) FROM sensor_samples
         WHERE session_id = ?1 AND device_id = ?2",
        [session_id, device_id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;
    let mut stmt = conn.prepare(
        "SELECT seq + 1, next - 1 FROM (
             SELECT seq, LEAD(seq) OVER (ORDER BY seq) AS next FROM sensor_samples
             WHERE session_id = ?1 AND device_id = ?2)
         WHERE next > seq + 1",
    )?;
    let missing = stmt
        .query_map([session_id, device_id], |r| {
            Ok((r.get::<_, i64>(0)? as Seq, r.get::<_, i64>(1)? as Seq))
        })?
        .collect::<Result<_, _>>()?;

    let mut stmt = conn.prepare(
        "SELECT stream, COUNT(*), MIN(source_phone_ns), MAX(source_phone_ns),
                MIN(dt), MAX(dt), SUM(dt <= 0)
         FROM (SELECT stream, source_phone_ns,
                      source_phone_ns - LAG(source_phone_ns) OVER (PARTITION BY stream ORDER BY seq) AS dt
               FROM sensor_samples WHERE session_id = ?1 AND device_id = ?2)
         GROUP BY stream ORDER BY stream",
    )?;
    let streams = stmt
        .query_map([session_id, device_id], |r| {
            let samples = r.get::<_, i64>(1)? as u64;
            let first_t_ns: Nanos = r.get(2)?;
            let last_t_ns: Nanos = r.get(3)?;
            let span = (last_t_ns - first_t_ns) as f64 / 1e9;
            Ok(StreamReport {
                stream: r.get(0)?,
                samples,
                first_t_ns,
                last_t_ns,
                rate_hz: (samples > 1 && span > 0.0).then(|| (samples - 1) as f64 / span),
                min_interval_ns: r.get(4)?,
                max_interval_ns: r.get(5)?,
                non_increasing_timestamps: r.get::<_, Option<i64>>(6)?.unwrap_or(0) as u64,
            })
        })?
        .collect::<Result<_, _>>()?;

    let bye_last_seq = last_bye(conn, session_id, device_id)?.map(|b| b.last_seq);
    let mut stmt = conn.prepare(
        "SELECT detail FROM session_events
         WHERE session_id = ?1 AND device_id = ?2 AND source = 'phone' AND kind = 'dropped_samples'",
    )?;
    let mut dropped_on_phone = 0;
    for detail in stmt.query_map([session_id, device_id], |r| r.get::<_, String>(0))? {
        let detail: serde_json::Value = serde_json::from_str(&detail?)?;
        dropped_on_phone += detail
            .get("count")
            .and_then(serde_json::Value::as_u64)
            .unwrap_or(0);
    }
    Ok(DeviceReport {
        device_id: device_id.to_owned(),
        samples: samples as u64,
        first_seq: first.map(|s| s as Seq),
        last_seq: last.map(|s| s as Seq),
        missing,
        bye_last_seq,
        dropped_on_phone,
        streams,
    })
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ExportSummary {
    pub messages: u64,
    pub samples: u64,
    pub sha256: String,
}

/// Writes a session as protocol NDJSON: `hello`, then batches, markers,
/// phone events, sites and clock results in phone-time order, then `bye` if one arrived. The output
/// validates with `cwb validate` and can be replayed or imported. Mac-side
/// ingest events are not protocol messages; `validate` reports them.
pub fn export(
    conn: &Connection,
    session_id: &str,
    out: &mut dyn Write,
) -> Result<ExportSummary, StorageError> {
    let mut summary = ExportSummary::default();
    let mut hasher = Sha256::new();
    let mut emit = |message: &Message, summary: &mut ExportSummary| -> Result<(), StorageError> {
        let mut line = serde_json::to_vec(message)?;
        line.push(b'\n');
        hasher.update(&line);
        out.write_all(&line)?;
        summary.messages += 1;
        Ok(())
    };
    let device_ids = device_ids(conn, session_id)?;
    if device_ids.is_empty() {
        return Err(StorageError::UnknownSession(session_id.to_owned()));
    }
    for device_id in device_ids {
        emit(
            &Message::Hello(stored_hello(conn, session_id, &device_id)?),
            &mut summary,
        )?;
        // (phone time, tie-break, message)
        let mut timeline: Vec<(Nanos, u8, Message)> = Vec::new();
        for batch in stored_batches(conn, session_id, &device_id)? {
            summary.samples += batch.samples.len() as u64;
            let t = batch.samples[0].t_ns();
            timeline.push((t, 0, Message::SampleBatch(batch)));
        }
        let mut stmt = conn.prepare(
            "SELECT marker_id, label, source_ns, notes FROM markers
             WHERE session_id = ?1 AND source = 'phone' ORDER BY source_ns, marker_id",
        )?;
        for marker in stmt.query_map([session_id], |r| {
            Ok(Marker {
                protocol_version: PROTOCOL_VERSION,
                session_id: session_id.to_owned(),
                device_id: device_id.clone(),
                marker_id: r.get(0)?,
                label: r.get(1)?,
                t_ns: r.get(2)?,
                notes: r.get(3)?,
            })
        })? {
            let marker = marker?;
            timeline.push((marker.t_ns, 1, Message::Marker(marker)));
        }
        let mut stmt = conn.prepare(
            "SELECT kind, severity, source_ns, detail FROM session_events
             WHERE session_id = ?1 AND device_id = ?2 AND source = 'phone' ORDER BY event_id",
        )?;
        let rows: Vec<(String, String, Nanos, String)> = stmt
            .query_map([session_id, &device_id], |r| {
                Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?))
            })?
            .collect::<Result<_, _>>()?;
        for (kind, severity, t_ns, detail) in rows {
            let event = Event {
                protocol_version: PROTOCOL_VERSION,
                session_id: session_id.to_owned(),
                device_id: device_id.clone(),
                t_ns,
                kind: serde_json::from_value(serde_json::Value::String(kind))?,
                severity: serde_json::from_value(serde_json::Value::String(severity))?,
                detail: serde_json::from_str(&detail)?,
            };
            timeline.push((t_ns, 2, Message::Event(event)));
        }
        for site in stored_sites(conn, session_id, &device_id)? {
            timeline.push((site.t_ns, 2, Message::Site(site)));
        }
        let mut stmt = conn.prepare(
            "SELECT exchange_index, phone_send_ns, mac_receive_ns, mac_send_ns, phone_receive_ns,
                    mac_clock_boot_id
             FROM clock_sync
             WHERE session_id = ?1 AND device_id = ?2 AND mac_clock_boot_id IS NOT NULL
             ORDER BY exchange_index",
        )?;
        for result in stmt.query_map([session_id, &device_id], |r| {
            Ok(ClockResult {
                protocol_version: PROTOCOL_VERSION,
                session_id: session_id.to_owned(),
                device_id: device_id.clone(),
                exchange_index: r.get::<_, i64>(0)? as u64,
                phone_send_ns: r.get(1)?,
                mac_receive_ns: r.get(2)?,
                mac_send_ns: r.get(3)?,
                phone_receive_ns: r.get(4)?,
                mac_clock_boot_id: r.get(5)?,
            })
        })? {
            let result = result?;
            // The phone logs a result when the pong arrives.
            timeline.push((result.phone_receive_ns, 3, Message::ClockResult(result)));
        }
        timeline.sort_by_key(|(t, tie, _)| (*t, *tie));
        for (_, _, message) in &timeline {
            emit(message, &mut summary)?;
        }
        if let Some(bye) = last_bye(conn, session_id, &device_id)? {
            emit(&Message::Bye(bye), &mut summary)?;
        }
    }
    out.flush()?;
    summary.sha256 = hex(&hasher.finalize());
    Ok(summary)
}

fn stored_hello(
    conn: &Connection,
    session_id: &str,
    device_id: &str,
) -> Result<Hello, StorageError> {
    let row = conn.query_row(
        "SELECT vendor, model, os_or_firmware, app_version, phone_boot_id, sensor_availability,
                attitude_reference_frame, requested_interval_s, accel_g0_m_s2, streams
         FROM devices WHERE session_id = ?1 AND device_id = ?2 AND role = 'imu_phone'",
        [session_id, device_id],
        |r| {
            Ok((
                r.get::<_, Option<String>>(0)?,
                r.get::<_, Option<String>>(1)?,
                r.get::<_, Option<String>>(2)?,
                r.get::<_, Option<String>>(3)?,
                r.get::<_, Option<String>>(4)?,
                r.get::<_, Option<String>>(5)?,
                r.get::<_, Option<String>>(6)?,
                r.get::<_, Option<f64>>(7)?,
                r.get::<_, Option<f64>>(8)?,
                r.get::<_, Option<String>>(9)?,
            ))
        },
    )?;
    let missing =
        |field: &str| StorageError::Incomplete(format!("device {device_id}: {field} not stored"));
    let (vendor, model, os, app, boot, availability, frame, interval, g0, streams) = row;
    Ok(Hello {
        protocol_version: PROTOCOL_VERSION,
        session_id: session_id.to_owned(),
        device: DeviceInfo {
            device_id: device_id.to_owned(),
            vendor: vendor.ok_or_else(|| missing("vendor"))?,
            model: model.ok_or_else(|| missing("model"))?,
            os_version: os.ok_or_else(|| missing("os_version"))?,
            app_version: app.ok_or_else(|| missing("app_version"))?,
            boot_id: boot.ok_or_else(|| missing("boot_id"))?,
        },
        sensor_availability: serde_json::from_str(
            &availability.ok_or_else(|| missing("sensor_availability"))?,
        )?,
        streams: serde_json::from_str(&streams.ok_or_else(|| missing("streams"))?)?,
        attitude_reference_frame: serde_json::from_value(serde_json::Value::String(
            frame.ok_or_else(|| missing("attitude_reference_frame"))?,
        ))?,
        requested_interval_s: interval.ok_or_else(|| missing("requested_interval_s"))?,
        accel_g0_m_s2: g0.ok_or_else(|| missing("accel_g0_m_s2"))?,
    })
}

/// Stored samples grouped into contiguous batches of at most
/// [`EXPORT_BATCH_SAMPLES`]; a gap always starts a new batch.
fn stored_batches(
    conn: &Connection,
    session_id: &str,
    device_id: &str,
) -> Result<Vec<SampleBatch>, StorageError> {
    let mut stmt = conn.prepare(
        "SELECT seq, stream, source_phone_ns, q_w, q_x, q_y, q_z,
                rotation_rate_x, rotation_rate_y, rotation_rate_z,
                gravity_x, gravity_y, gravity_z, user_accel_x, user_accel_y, user_accel_z,
                accel_x, accel_y, accel_z,
                magnetic_field_x_ut, magnetic_field_y_ut, magnetic_field_z_ut, magnetic_accuracy
         FROM sensor_samples WHERE session_id = ?1 AND device_id = ?2 ORDER BY seq",
    )?;
    let mut batches: Vec<SampleBatch> = Vec::new();
    let mut rows = stmt.query([session_id, device_id])?;
    while let Some(row) = rows.next()? {
        let sample = sample_from_row(row)?;
        let seq = sample.seq();
        match batches.last_mut() {
            Some(b) if b.last_seq + 1 == seq && b.samples.len() < EXPORT_BATCH_SAMPLES => {
                b.last_seq = seq;
                b.samples.push(sample);
            }
            _ => batches.push(SampleBatch {
                protocol_version: PROTOCOL_VERSION,
                session_id: session_id.to_owned(),
                device_id: device_id.to_owned(),
                first_seq: seq,
                last_seq: seq,
                samples: vec![sample],
            }),
        }
    }
    Ok(batches)
}

fn sample_from_row(r: &Row<'_>) -> Result<Sample, StorageError> {
    let seq = r.get::<_, i64>(0)? as Seq;
    let stream: String = r.get(1)?;
    let t_ns: Nanos = r.get(2)?;
    let opt3 = |i: usize| -> rusqlite::Result<Option<[f64; 3]>> {
        Ok(
            match (
                r.get::<_, Option<f64>>(i)?,
                r.get::<_, Option<f64>>(i + 1)?,
                r.get::<_, Option<f64>>(i + 2)?,
            ) {
                (Some(x), Some(y), Some(z)) => Some([x, y, z]),
                _ => None,
            },
        )
    };
    let need = |v: Option<[f64; 3]>, field: &str| {
        v.ok_or_else(|| StorageError::Incomplete(format!("seq {seq}: {stream} {field} is null")))
    };
    Ok(match stream.as_str() {
        "device_motion" => {
            let q: [Option<f64>; 4] = [r.get(3)?, r.get(4)?, r.get(5)?, r.get(6)?];
            let [Some(w), Some(x), Some(y), Some(z)] = q else {
                return Err(StorageError::Incomplete(format!(
                    "seq {seq}: attitude is null"
                )));
            };
            let accuracy: Option<String> = r.get(22)?;
            Sample::DeviceMotion(DeviceMotionSample {
                seq,
                t_ns,
                attitude: Quaternion { w, x, y, z },
                rotation_rate: need(opt3(7)?, "rotation_rate")?,
                gravity: need(opt3(10)?, "gravity")?,
                user_accel: need(opt3(13)?, "user_accel")?,
                magnetic_field_ut: opt3(19)?,
                magnetic_accuracy: accuracy
                    .map(|a| serde_json::from_value(serde_json::Value::String(a)))
                    .transpose()?,
            })
        }
        "gyro" => Sample::Gyro(GyroSample {
            seq,
            t_ns,
            rotation_rate: need(opt3(7)?, "rotation_rate")?,
        }),
        "accel" => Sample::Accel(AccelSample {
            seq,
            t_ns,
            accel: need(opt3(16)?, "accel")?,
        }),
        "magnetometer" => Sample::Magnetometer(MagnetometerSample {
            seq,
            t_ns,
            magnetic_field_ut: need(opt3(19)?, "magnetic_field_ut")?,
        }),
        other => {
            return Err(StorageError::Incomplete(format!(
                "seq {seq}: unknown stream {other}"
            )));
        }
    })
}

/// The most recent `bye`, rebuilt from the Mac event that recorded it.
fn last_bye(
    conn: &Connection,
    session_id: &str,
    device_id: &str,
) -> Result<Option<Bye>, StorageError> {
    let detail: Option<String> = conn
        .query_row(
            "SELECT detail FROM session_events
             WHERE session_id = ?1 AND device_id = ?2 AND source = 'mac' AND kind = 'bye'
             ORDER BY event_id DESC LIMIT 1",
            [session_id, device_id],
            |r| r.get(0),
        )
        .optional()?;
    let Some(detail) = detail else {
        return Ok(None);
    };
    let detail: serde_json::Value = serde_json::from_str(&detail)?;
    let reason: ByeReason = serde_json::from_value(detail["reason"].clone())?;
    Ok(Some(Bye {
        protocol_version: PROTOCOL_VERSION,
        session_id: session_id.to_owned(),
        device_id: device_id.to_owned(),
        last_seq: detail["last_seq"].as_u64(),
        reason,
    }))
}

#[derive(Debug, Clone, Default, Serialize)]
pub struct ImportSummary {
    pub session_id: Option<String>,
    pub created: bool,
    pub lines: u64,
    pub stored_samples: u64,
    pub duplicate_samples: u64,
    pub conflicting_samples: u64,
    pub markers: u64,
    pub events: u64,
    pub sites: u64,
    pub clock_exchanges: u64,
    /// Lines skipped: not protocol messages, or a truncated last line.
    pub skipped: Vec<String>,
    pub sha256: String,
}

/// Imports a phone session log (or an export) through the same path the
/// receiver uses. Importing over a session received live fills in whatever
/// the network missed and skips what is already stored (ADR 0006).
pub fn import(
    store: &mut Store,
    input: &mut dyn BufRead,
    now_ns: &dyn Fn() -> Nanos,
) -> Result<ImportSummary, StorageError> {
    let mut summary = ImportSummary::default();
    let mut hasher = Sha256::new();
    let mut lines = Vec::new();
    let mut buf = Vec::new();
    while input.read_until(b'\n', &mut buf)? > 0 {
        hasher.update(&buf);
        lines.push(std::mem::take(&mut buf));
    }
    summary.sha256 = hex(&hasher.finalize());
    let total = lines.len();
    for (index, line) in lines.iter().enumerate() {
        let number = index + 1;
        if line.iter().all(u8::is_ascii_whitespace) {
            continue;
        }
        summary.lines += 1;
        let message: Message = match serde_json::from_slice(line) {
            Ok(m) => m,
            Err(e) if number == total && !line.ends_with(b"\n") => {
                summary
                    .skipped
                    .push(format!("line {number}: truncated last line ({e})"));
                continue;
            }
            Err(e) => {
                summary.skipped.push(format!("line {number}: {e}"));
                continue;
            }
        };
        // The same check the receiver applies to every message.
        if let Err(errors) = cwb_protocol::schema::validate(&serde_json::from_slice(line)?) {
            summary
                .skipped
                .push(format!("line {number}: {}", errors.join("; ")));
            continue;
        }
        let now = now_ns();
        match message {
            Message::Hello(hello) => match store.hello(&hello, now)? {
                HelloOutcome::Accepted { created, .. } => {
                    summary.created |= created;
                    summary.session_id = Some(hello.session_id.clone());
                }
                HelloOutcome::Rejected { reason, .. } => {
                    return Err(StorageError::Rejected(reason));
                }
            },
            Message::SampleBatch(batch) => {
                let outcome = store.batch(&batch, now)?;
                summary.stored_samples += outcome.stored as u64;
                summary.duplicate_samples += outcome.duplicates as u64;
                summary.conflicting_samples += outcome.conflicts as u64;
            }
            Message::Marker(marker) => summary.markers += u64::from(store.marker(&marker)?),
            Message::Event(event) => summary.events += u64::from(store.phone_event(&event, now)?),
            Message::Site(site) => summary.sites += u64::from(store.site(&site, now)?),
            Message::ClockResult(result) => {
                summary.clock_exchanges += u64::from(store.clock_result(&result)?);
            }
            Message::Bye(bye) => {
                store.bye(&bye, now)?;
            }
            other => summary.skipped.push(format!(
                "line {number}: {} is not part of a session log",
                serde_json::to_value(&other)?["type"]
            )),
        }
    }
    if let Some(session_id) = &summary.session_id {
        store.mac_event(
            session_id,
            None,
            "imported",
            "info",
            serde_json::json!({
                "sha256": summary.sha256,
                "stored_samples": summary.stored_samples,
                "duplicate_samples": summary.duplicate_samples,
                "skipped_lines": summary.skipped.len(),
            }),
            now_ns(),
        )?;
    }
    Ok(summary)
}

/// The newest precise phone fix no less accurate than `max_accuracy_m`.
#[derive(Debug, Clone)]
pub struct LatestFix {
    pub session_id: String,
    pub session_created_utc: String,
    pub environment: String,
    pub location: Location,
}

pub fn latest_fix(
    conn: &Connection,
    max_accuracy_m: f64,
) -> Result<Option<LatestFix>, StorageError> {
    Ok(conn
        .query_row(
            "SELECT w.session_id, s.created_utc, w.environment, w.latitude, w.longitude,
                    w.horizontal_accuracy_m, w.altitude_m, w.vertical_accuracy_m, w.fix_age_s
             FROM session_sites w JOIN sessions s USING (session_id)
             WHERE w.location_status = 'fix' AND w.precise = 1 AND w.horizontal_accuracy_m <= ?1
             ORDER BY s.created_utc DESC, w.source_ns DESC LIMIT 1",
            [max_accuracy_m],
            |r| {
                Ok(LatestFix {
                    session_id: r.get(0)?,
                    session_created_utc: r.get(1)?,
                    environment: r.get(2)?,
                    location: Location {
                        latitude: r.get(3)?,
                        longitude: r.get(4)?,
                        horizontal_accuracy_m: r.get(5)?,
                        altitude_m: r.get(6)?,
                        vertical_accuracy_m: r.get(7)?,
                        precise: true,
                        fix_age_s: r.get(8)?,
                    },
                })
            },
        )
        .optional()?)
}

/// A device's stored sites, as the phone sent them.
pub fn stored_sites(
    conn: &Connection,
    session_id: &str,
    device_id: &str,
) -> Result<Vec<Site>, StorageError> {
    let mut stmt = conn.prepare(
        "SELECT site_id, source_ns, environment, location_status, latitude, longitude,
                horizontal_accuracy_m, altitude_m, vertical_accuracy_m, precise, fix_age_s
         FROM session_sites WHERE session_id = ?1 AND device_id = ?2
         ORDER BY source_ns, site_id",
    )?;
    let rows = stmt.query_map([session_id, device_id], |r| {
        let location = match r.get::<_, Option<f64>>(4)? {
            Some(latitude) => Some(Location {
                latitude,
                longitude: r.get(5)?,
                horizontal_accuracy_m: r.get(6)?,
                altitude_m: r.get(7)?,
                vertical_accuracy_m: r.get(8)?,
                precise: r.get(9)?,
                fix_age_s: r.get(10)?,
            }),
            None => None,
        };
        Ok((
            r.get::<_, String>(0)?,
            r.get::<_, Nanos>(1)?,
            r.get::<_, String>(2)?,
            r.get::<_, String>(3)?,
            location,
        ))
    })?;
    let mut out = Vec::new();
    for row in rows {
        let (site_id, t_ns, environment, status, location) = row?;
        out.push(Site {
            protocol_version: PROTOCOL_VERSION,
            session_id: session_id.to_owned(),
            device_id: device_id.to_owned(),
            site_id,
            t_ns,
            environment: serde_json::from_value(serde_json::Value::String(environment))?,
            location_status: serde_json::from_value(serde_json::Value::String(status))?,
            location,
        });
    }
    Ok(out)
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

fn short(id: &str) -> &str {
    id.get(..8).unwrap_or(id)
}
