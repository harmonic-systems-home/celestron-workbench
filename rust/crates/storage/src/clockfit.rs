//! Clock models: phone time to Mac time from four-timestamp exchanges
//! (ADR 0001, ADR 0007).
//!
//! Each exchange gives an offset (Mac minus phone, at the exchange's phone
//! midpoint) and a round trip. Queueing and Wi-Fi stalls only ever add delay,
//! so exchanges with short round trips are the trustworthy ones: the fit keeps
//! those at or below the median round trip and fits a straight line, offset
//! plus drift, through them. There is one model per Mac clock domain, since a
//! receiver restart starts a new Mac clock.
//!
//! The median alone fails when most exchanges are delayed, as when pings
//! queue behind a backlog of samples resent after a reconnect (seconds each
//! way, docs/observations.md O6). So the fit also drops any exchange more
//! than [`MAX_EXCESS_ROUND_TRIP_NS`] slower than the fastest.
//!
//! Uncertainty: no exchange can see a constant difference between the outbound
//! and return delays, so the true offset lies within half the round trip of
//! the measured one. The fit averages every kept exchange, so its bound is
//! half the longest kept round trip, plus twice the RMS residual of the fit.

use cwb_protocol::Nanos;
use rusqlite::{Connection, params};
use serde::Serialize;

use crate::{StorageError, clock::utc_now};

pub const METHOD: &str = "min_rtt_linear_v2";
/// Drift is fitted only over at least this span of kept exchanges...
pub const MIN_DRIFT_SPAN_NS: Nanos = 30_000_000_000;
/// ...and with at least this many; otherwise it is reported as zero.
pub const MIN_DRIFT_EXCHANGES: usize = 3;
/// Exchanges whose round trip exceeds the fastest by more than this are dropped.
pub const MAX_EXCESS_ROUND_TRIP_NS: Nanos = 250_000_000;

/// One completed exchange, in its two clock domains.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Exchange {
    pub index: u64,
    pub phone_send_ns: Nanos,
    pub mac_receive_ns: Nanos,
    pub mac_send_ns: Nanos,
    pub phone_receive_ns: Nanos,
}

impl Exchange {
    /// Time on the network, excluding the Mac's turnaround.
    pub fn round_trip_ns(&self) -> Nanos {
        (self.phone_receive_ns - self.phone_send_ns) - (self.mac_send_ns - self.mac_receive_ns)
    }

    /// Mac time minus phone time, assuming equal delays each way.
    pub fn offset_ns(&self) -> f64 {
        ((self.mac_receive_ns - self.phone_send_ns) + (self.mac_send_ns - self.phone_receive_ns))
            as f64
            / 2.0
    }

    pub fn phone_mid_ns(&self) -> Nanos {
        self.phone_send_ns + (self.phone_receive_ns - self.phone_send_ns) / 2
    }
}

/// `mac_ns = phone_ns + offset_ns + drift_ppb / 1e9 * (phone_ns - valid_from_phone_ns)`,
/// valid between the first and last exchange of one Mac clock domain.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct ClockModel {
    pub mac_clock_boot_id: String,
    pub phone_boot_id: Option<String>,
    pub valid_from_phone_ns: Nanos,
    pub valid_to_phone_ns: Nanos,
    pub offset_ns: Nanos,
    pub drift_ppb: f64,
    pub drift_fitted: bool,
    pub uncertainty_ns: Nanos,
    pub exchanges: usize,
    pub used: usize,
    pub round_trip_min_ns: Nanos,
    pub round_trip_median_ns: Nanos,
    pub residual_rms_ns: f64,
    pub residual_max_ns: f64,
}

impl ClockModel {
    /// Phone time to Mac time. The result carries `uncertainty_ns`.
    pub fn to_mac_ns(&self, phone_ns: Nanos) -> Nanos {
        let elapsed = (phone_ns - self.valid_from_phone_ns) as f64;
        phone_ns + self.offset_ns + (self.drift_ppb / 1e9 * elapsed).round() as Nanos
    }

    /// Whether an interval between a phone time and a Mac time can be
    /// claimed: it must exceed the alignment uncertainty (ADR 0001).
    pub fn resolves(&self, interval_ns: Nanos) -> bool {
        interval_ns.abs() > self.uncertainty_ns
    }
}

/// Fits one Mac clock domain. `None` when there are no exchanges.
pub fn fit(
    mac_clock_boot_id: &str,
    phone_boot_id: Option<&str>,
    exchanges: &[Exchange],
) -> Option<ClockModel> {
    let valid_from = exchanges.iter().map(|e| e.phone_send_ns).min()?;
    let valid_to = exchanges.iter().map(|e| e.phone_receive_ns).max()?;
    let mut round_trips: Vec<Nanos> = exchanges.iter().map(Exchange::round_trip_ns).collect();
    round_trips.sort_unstable();
    let median = round_trips[(round_trips.len() - 1) / 2];
    let bound = median.min(round_trips[0].saturating_add(MAX_EXCESS_ROUND_TRIP_NS));
    let kept: Vec<&Exchange> = exchanges
        .iter()
        .filter(|e| e.round_trip_ns() <= bound)
        .collect();
    let longest_kept = kept.iter().map(|e| e.round_trip_ns()).max().unwrap_or(0);

    let points: Vec<(f64, f64)> = kept
        .iter()
        .map(|e| ((e.phone_mid_ns() - valid_from) as f64, e.offset_ns()))
        .collect();
    let n = points.len() as f64;
    let mean_x = points.iter().map(|p| p.0).sum::<f64>() / n;
    let mean_y = points.iter().map(|p| p.1).sum::<f64>() / n;
    let sxx: f64 = points.iter().map(|p| (p.0 - mean_x).powi(2)).sum();
    let span = points.iter().map(|p| p.0).fold(f64::MIN, f64::max)
        - points.iter().map(|p| p.0).fold(f64::MAX, f64::min);
    let drift_fitted =
        kept.len() >= MIN_DRIFT_EXCHANGES && span >= MIN_DRIFT_SPAN_NS as f64 && sxx > 0.0;
    let slope = if drift_fitted {
        points
            .iter()
            .map(|p| (p.0 - mean_x) * (p.1 - mean_y))
            .sum::<f64>()
            / sxx
    } else {
        0.0
    };
    let intercept = mean_y - slope * mean_x;
    let residuals: Vec<f64> = points
        .iter()
        .map(|p| p.1 - (intercept + slope * p.0))
        .collect();
    let residual_rms = (residuals.iter().map(|r| r * r).sum::<f64>() / n).sqrt();
    let residual_max = residuals.iter().map(|r| r.abs()).fold(0.0, f64::max);

    Some(ClockModel {
        mac_clock_boot_id: mac_clock_boot_id.to_owned(),
        phone_boot_id: phone_boot_id.map(str::to_owned),
        valid_from_phone_ns: valid_from,
        valid_to_phone_ns: valid_to,
        offset_ns: intercept.round() as Nanos,
        drift_ppb: slope * 1e9,
        drift_fitted,
        uncertainty_ns: (longest_kept.max(0) as f64 / 2.0 + 2.0 * residual_rms).ceil() as Nanos,
        exchanges: exchanges.len(),
        used: kept.len(),
        round_trip_min_ns: round_trips[0],
        round_trip_median_ns: median,
        residual_rms_ns: residual_rms,
        residual_max_ns: residual_max,
    })
}

/// Stored exchanges for one device, grouped by Mac clock domain in order of
/// first exchange. Exchanges without a domain (none are written) are skipped.
pub fn exchanges(
    conn: &Connection,
    session_id: &str,
    device_id: &str,
) -> Result<Vec<(String, Vec<Exchange>)>, StorageError> {
    let mut stmt = conn.prepare(
        "SELECT mac_clock_boot_id, exchange_index, phone_send_ns, mac_receive_ns, mac_send_ns,
                phone_receive_ns
         FROM clock_sync
         WHERE session_id = ?1 AND device_id = ?2 AND mac_clock_boot_id IS NOT NULL
         ORDER BY exchange_index",
    )?;
    let mut groups: Vec<(String, Vec<Exchange>)> = Vec::new();
    for row in stmt.query_map([session_id, device_id], |r| {
        Ok((
            r.get::<_, String>(0)?,
            Exchange {
                index: r.get::<_, i64>(1)? as u64,
                phone_send_ns: r.get(2)?,
                mac_receive_ns: r.get(3)?,
                mac_send_ns: r.get(4)?,
                phone_receive_ns: r.get(5)?,
            },
        ))
    })? {
        let (boot, exchange) = row?;
        match groups.iter_mut().find(|(b, _)| *b == boot) {
            Some((_, list)) => list.push(exchange),
            None => groups.push((boot, vec![exchange])),
        }
    }
    Ok(groups)
}

/// Fits every device and Mac clock domain in a session, without storing.
pub fn fit_session(
    conn: &Connection,
    session_id: &str,
) -> Result<Vec<(String, ClockModel)>, StorageError> {
    let mut stmt = conn.prepare(
        "SELECT device_id, phone_boot_id FROM devices WHERE session_id = ?1 ORDER BY device_id",
    )?;
    let devices: Vec<(String, Option<String>)> = stmt
        .query_map([session_id], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<Result<_, _>>()?;
    if devices.is_empty() {
        return Err(StorageError::UnknownSession(session_id.to_owned()));
    }
    let mut models = Vec::new();
    for (device_id, phone_boot_id) in devices {
        for (boot, list) in exchanges(conn, session_id, &device_id)? {
            if let Some(model) = fit(&boot, phone_boot_id.as_deref(), &list) {
                models.push((device_id.clone(), model));
            }
        }
    }
    Ok(models)
}

/// Stores fitted models as new rows; earlier models are kept. Returns their IDs.
pub fn store(
    conn: &Connection,
    session_id: &str,
    models: &[(String, ClockModel)],
) -> Result<Vec<String>, StorageError> {
    let software = format!("cwb-storage {}", env!("CARGO_PKG_VERSION"));
    let created = utc_now();
    let mut ids = Vec::new();
    for (device_id, model) in models {
        let id = uuid::Uuid::new_v4().to_string();
        let summary = serde_json::json!({
            "drift_fitted": model.drift_fitted,
            "exchanges": model.exchanges,
            "used": model.used,
            "round_trip_min_ns": model.round_trip_min_ns,
            "round_trip_median_ns": model.round_trip_median_ns,
            "residual_rms_ns": model.residual_rms_ns,
            "residual_max_ns": model.residual_max_ns,
        });
        conn.execute(
            "INSERT INTO clock_models (clock_model_id, session_id, device_id, method,
                 software_version, valid_from_phone_ns, valid_to_phone_ns, offset_ns, drift_ppb,
                 uncertainty_ns, residuals, created_utc, mac_clock_boot_id, phone_boot_id)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14)",
            params![
                id,
                session_id,
                device_id,
                METHOD,
                software,
                model.valid_from_phone_ns,
                model.valid_to_phone_ns,
                model.offset_ns,
                model.drift_ppb,
                model.uncertainty_ns,
                summary.to_string(),
                created,
                model.mac_clock_boot_id,
                model.phone_boot_id
            ],
        )?;
        ids.push(id);
    }
    Ok(ids)
}
