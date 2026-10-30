//! Checks before the adapter starts: the hand controller answers, both
//! motors answer and no goto is running. Then tracking off (`T 00`) is sent
//! whatever tracking reads, which also clears any variable rate left on the
//! motors. Nothing here moves the mount; tracking off stops motion.

use cwb_celestron_discovery::{
    HandController, Link, Outcome, Query,
    query::{Device, Sense, Value},
    transact,
};
use cwb_mount_core::{MountIdentity, MountQueries};

use crate::encode::TRACKING_OFF;

#[derive(Debug, Clone, PartialEq)]
pub struct Prepared {
    pub identity: MountIdentity,
    /// The mount's own axis angles before any motion.
    pub positions_deg: [f64; 2],
    /// Anti-backlash settings, [azimuth, altitude] × [positive, negative];
    /// `None` where the motor didn't answer.
    pub backlash: [[Option<u8>; 2]; 2],
    /// Things done or noticed on the way, for the run log.
    pub notes: Vec<String>,
}

pub fn prepare<L: Link>(link: L) -> (L, Result<Prepared, String>) {
    let mut hc = HandController::new(link);
    let result = checks(&mut hc);
    (hc.into_parts().0, result)
}

fn checks<L: Link>(hc: &mut HandController<L>) -> Result<Prepared, String> {
    let mut notes = Vec::new();
    if !matches!(hc.query(Query::Echo(b'x')).value, Some(Value::Echo(b'x'))) {
        return Err(
            "the hand controller didn't echo: check the port, cable and that it has finished starting up"
                .into(),
        );
    }
    let identity = hc.identify().map_err(|e| e.0)?;
    for d in [Device::AzmMotor, Device::AltMotor] {
        if hc.query(Query::DeviceVersion(d)).value.is_none() {
            return Err(format!("the {d:?} motor controller didn't answer"));
        }
    }
    match hc.query(Query::GotoInProgress).value {
        Some(Value::Flag(false)) => {}
        Some(_) => return Err("a goto is in progress: wait for it to finish".into()),
        None => return Err("the goto status query went unanswered".into()),
    }
    // Tracking off, always: it also clears a variable rate left on a motor
    // controller by earlier software, which "tracking 0" doesn't reveal and
    // which keeps the axis creeping (docs/observations.md, O1).
    let mode = match hc.query(Query::TrackingMode).value {
        Some(Value::TrackingMode(mode)) => mode,
        _ => return Err("the tracking mode query went unanswered".into()),
    };
    let (outcome, _) = transact(hc.link_mut(), &TRACKING_OFF, 0, false);
    if outcome != Outcome::Ok {
        return Err(format!("turning tracking off failed ({outcome:?})"));
    }
    if !matches!(
        hc.query(Query::TrackingMode).value,
        Some(Value::TrackingMode(0))
    ) {
        return Err(format!("tracking is on (mode {mode}) and stayed on"));
    }
    notes.push(if mode == 0 {
        "tracking off sent (it read off already)".into()
    } else {
        format!("tracking was on (mode {mode}); turned it off")
    });
    let positions_deg = hc.axis_positions_deg().map_err(|e| e.0)?;
    let backlash = [Device::AzmMotor, Device::AltMotor].map(|d| {
        [Sense::Positive, Sense::Negative].map(|sense| {
            match hc.query(Query::Backlash(d, sense)).value {
                Some(Value::Backlash(v)) => Some(v),
                _ => None,
            }
        })
    });
    Ok(Prepared {
        identity,
        positions_deg,
        backlash,
        notes,
    })
}
