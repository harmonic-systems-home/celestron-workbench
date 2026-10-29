//! A stored session loaded for analysis: plain arrays in phone time.

use cwb_protocol::{Nanos, Seq};
use cwb_storage::{
    clockfit::{self, ClockModel},
    sessions,
};
use rusqlite::Connection;
use serde::Serialize;

use crate::AnalysisError;

/// One fused device-motion sample (ADR 0002 units: rad/s, m/s²).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Motion {
    pub t_ns: Nanos,
    /// (w, x, y, z), rotating device-frame vectors into the reference frame.
    pub q: [f64; 4],
    pub rate: [f64; 3],
    pub gravity: [f64; 3],
}

/// One raw gyro (rad/s) or accelerometer (m/s²) sample.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Raw {
    pub t_ns: Nanos,
    pub v: [f64; 3],
}

#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Source {
    pub session_id: String,
    pub device_id: String,
    pub created_utc: String,
    pub status: String,
    pub app_version: Option<String>,
    pub attitude_reference_frame: Option<String>,
    pub requested_interval_s: Option<f64>,
    /// SHA-256 of `cwb session export` for this session: names the exact data analysed.
    pub export_sha256: String,
}

#[derive(Debug, Clone, PartialEq)]
pub struct SessionData {
    pub source: Source,
    pub motion: Vec<Motion>,
    pub gyro: Vec<Raw>,
    pub accel: Vec<Raw>,
    pub markers: Vec<(String, Nanos)>,
    /// Inclusive seq ranges missing between the first and last stored seq.
    pub missing: Vec<(Seq, Seq)>,
    pub dropped_on_phone: u64,
    pub clock: Vec<ClockModel>,
}

/// Loads the session's one phone. Sessions with several devices need `device`.
pub fn load(
    conn: &Connection,
    session_id: &str,
    device: Option<&str>,
) -> Result<SessionData, AnalysisError> {
    let report = sessions::validate(conn, session_id)?;
    let devices: Vec<_> = report
        .devices
        .iter()
        .filter(|d| device.is_none_or(|id| d.device_id.starts_with(id)))
        .collect();
    let device = match devices.as_slice() {
        [one] => *one,
        [] => return Err(AnalysisError::NoDevice(session_id.to_owned())),
        _ => return Err(AnalysisError::SeveralDevices(session_id.to_owned())),
    };
    let device_id = device.device_id.clone();
    let export_sha256 = sessions::export(conn, session_id, &mut std::io::sink())?.sha256;
    let (app_version, frame, interval) = conn.query_row(
        "SELECT app_version, attitude_reference_frame, requested_interval_s
         FROM devices WHERE session_id = ?1 AND device_id = ?2",
        [session_id, &device_id],
        |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
    )?;

    let mut stmt = conn.prepare(
        "SELECT source_phone_ns, q_w, q_x, q_y, q_z, rotation_rate_x, rotation_rate_y,
                rotation_rate_z, gravity_x, gravity_y, gravity_z
         FROM sensor_samples
         WHERE session_id = ?1 AND device_id = ?2 AND stream = 'device_motion'
         ORDER BY source_phone_ns, seq",
    )?;
    let motion = stmt
        .query_map([session_id, &device_id], |r| {
            Ok(Motion {
                t_ns: r.get(0)?,
                q: [r.get(1)?, r.get(2)?, r.get(3)?, r.get(4)?],
                rate: [r.get(5)?, r.get(6)?, r.get(7)?],
                gravity: [r.get(8)?, r.get(9)?, r.get(10)?],
            })
        })?
        .collect::<Result<_, _>>()?;
    let raw = |stream: &str, columns: &str| -> Result<Vec<Raw>, AnalysisError> {
        let mut stmt = conn.prepare(&format!(
            "SELECT source_phone_ns, {columns} FROM sensor_samples
             WHERE session_id = ?1 AND device_id = ?2 AND stream = ?3
             ORDER BY source_phone_ns, seq"
        ))?;
        Ok(stmt
            .query_map([session_id, &device_id, stream], |r| {
                Ok(Raw {
                    t_ns: r.get(0)?,
                    v: [r.get(1)?, r.get(2)?, r.get(3)?],
                })
            })?
            .collect::<Result<_, _>>()?)
    };
    let gyro = raw("gyro", "rotation_rate_x, rotation_rate_y, rotation_rate_z")?;
    let accel = raw("accel", "accel_x, accel_y, accel_z")?;

    let mut stmt = conn.prepare(
        "SELECT label, source_ns FROM markers
         WHERE session_id = ?1 AND source_clock = 'phone' ORDER BY source_ns, marker_id",
    )?;
    let markers = stmt
        .query_map([session_id], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<Result<_, _>>()?;
    let clock = clockfit::fit_session(conn, session_id)?
        .into_iter()
        .filter(|(d, _)| *d == device_id)
        .map(|(_, m)| m)
        .collect();

    Ok(SessionData {
        source: Source {
            session_id: session_id.to_owned(),
            device_id,
            created_utc: report.session.created_utc.clone(),
            status: report.session.status.clone(),
            app_version,
            attitude_reference_frame: frame,
            requested_interval_s: interval,
            export_sha256,
        },
        motion,
        gyro,
        accel,
        markers,
        missing: device.missing.clone(),
        dropped_on_phone: device.dropped_on_phone,
        clock,
    })
}
