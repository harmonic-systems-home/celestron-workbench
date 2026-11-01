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

/// Arms, retrying while the first fresh reads come in.
fn arm(session: u64) -> Value {
    let end = Instant::now() + Duration::from_millis(3_000);
    loop {
        let r = command_json(session, r#"{"op": "arm"}"#);
        if r["ok"] == true || Instant::now() > end {
            return r;
        }
        sleep(Duration::from_millis(100));
    }
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
    let armed = arm(id);
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

#[test]
fn the_trace_records_traffic_and_reads_are_slow_until_armed() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("traces/t.ndjson");
    let options = serde_json::json!({ "port": "simulate", "trace": path });
    let r = open_json(&options.to_string());
    assert_eq!(r["ok"], true, "{r}");
    let id = r["session"].as_u64().unwrap();
    sleep(Duration::from_millis(4_500));
    assert_eq!(
        command_json(id, r#"{"op": "reference", "altitude_deg": 30.0}"#)["ok"],
        true
    );
    assert_eq!(arm(id)["ok"], true);
    sleep(Duration::from_millis(1_100));
    close(id);

    let lines: Vec<Value> = std::fs::read_to_string(&path)
        .unwrap()
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    let events =
        |name: &str| -> Vec<&Value> { lines.iter().filter(|l| l["event"] == name).collect() };
    for name in [
        "trace_start",
        "open",
        "opened",
        "tx",
        "rx",
        "request",
        "state",
    ] {
        assert!(!events(name).is_empty(), "no {name} line");
    }
    assert_eq!(events("open")[0]["port"], "simulate");
    // Unarmed: a read at once, then one every 2 s (three in 4.5 s); armed:
    // four a second.
    let request_ns = events("request")[0]["t_ns"].as_i64().unwrap();
    let before = events("position")
        .iter()
        .filter(|l| l["t_ns"].as_i64().unwrap() < request_ns)
        .count();
    assert!((2..=4).contains(&before), "{before} reads before arming");
    let armed_ns = events("state")
        .iter()
        .find(|l| l["to"] == "Armed")
        .expect("armed")["t_ns"]
        .as_i64()
        .unwrap();
    let after = events("position")
        .iter()
        .filter(|l| l["t_ns"].as_i64().unwrap() > armed_ns)
        .count();
    assert!(after >= 3, "{after} reads in the second after arming");
}
