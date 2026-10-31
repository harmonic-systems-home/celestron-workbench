//! The JSON interface end to end, on the simulated hand controller and mount
//! (real time: the session runs its own thread).

use std::{
    thread::sleep,
    time::{Duration, Instant},
};

use cwb_mount_ffi::{close, command_json, open_json, status_json};
use serde_json::Value;

fn open() -> u64 {
    let r = open_json(r#"{"port": "simulate", "safety": {"max_goto_deg": 0.5}}"#);
    assert_eq!(r["ok"], true, "{r}");
    assert_eq!(r["opened"]["simulated"], true);
    r["session"].as_u64().unwrap()
}

/// Polls status until `done` holds or `ms` pass.
fn wait(session: u64, ms: u64, done: impl Fn(&Value) -> bool) -> Value {
    let end = Instant::now() + Duration::from_millis(ms);
    loop {
        let s = status_json(session);
        if done(&s) || Instant::now() > end {
            return s;
        }
        sleep(Duration::from_millis(20));
    }
}

#[test]
fn a_goto_runs_with_encoder_feedback_through_the_json_interface() {
    let id = open();
    // Idle reads arrive every 250 ms.
    let s = wait(id, 2_000, |s| s["positions_deg"].is_array());
    assert!(s["positions_deg"].is_array(), "{s}");

    // No altitude reference yet: the envelope can't be checked.
    sleep(Duration::from_millis(600));
    let refused = command_json(id, r#"{"op": "arm"}"#);
    assert_eq!(refused["ok"], false, "{refused}");

    assert_eq!(
        command_json(id, r#"{"op": "reference", "altitude_deg": 30.0}"#)["ok"],
        true
    );
    sleep(Duration::from_millis(600));
    let armed = command_json(id, r#"{"op": "arm"}"#);
    assert_eq!(armed["ok"], true, "{armed}");
    let alt = status_json(id)["altitude_deg"].as_f64().unwrap();
    assert!((alt - 30.0).abs() < 0.01, "{alt}");

    let start = status_json(id)["positions_deg"][0].as_f64().unwrap();
    let g = command_json(
        id,
        r#"{"op": "goto", "axis": "azimuth", "delta_deg": 0.05, "approach": "positive"}"#,
    );
    assert_eq!(g["ok"], true, "{g}");
    let s = wait(id, 8_000, |s| {
        s["state"] == "Armed"
            && s["last_record"]["stages"]
                .as_array()
                .and_then(|st| st.last())
                .is_some_and(|last| last[0] == "completed")
    });
    assert_eq!(s["state"], "Armed", "{s}");
    assert!(s["last_fault"].is_null(), "{s}");
    let s = wait(id, 1_000, |s| {
        s["positions_deg"][0]
            .as_f64()
            .is_some_and(|d| (d - start - 0.05).abs() < 0.001)
    });
    let end = s["positions_deg"][0].as_f64().unwrap();
    assert!((end - start - 0.05).abs() < 0.001, "{start} -> {end}");

    assert_eq!(close(id)["ok"], true);
    assert_eq!(status_json(id)["ok"], false);
}

#[test]
fn bad_requests_are_errors_not_panics() {
    assert_eq!(open_json("not json")["ok"], false);
    assert!(
        command_json(999, r#"{"op": "arm"}"#)["error"]
            .as_str()
            .unwrap()
            .contains("no session")
    );
    let id = open();
    let r = command_json(id, r#"{"op": "fly"}"#);
    assert_eq!(r["ok"], false, "{r}");
    // Timed moves don't exist here: only gotos.
    let r = command_json(id, r#"{"op": "move", "axis": "azimuth"}"#);
    assert_eq!(r["ok"], false, "{r}");
    close(id);
}
