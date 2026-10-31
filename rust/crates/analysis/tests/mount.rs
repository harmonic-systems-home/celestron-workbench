//! The mount report (ADR 0017) on synthetic run logs with known backlash,
//! take-up and speeds.

use cwb_analysis::{
    mount::{self, History, Kind, MountConfig, RunLog},
    mount_report,
};
use serde_json::json;

const SLACK: f64 = 150.0; // ″ of lost motion a reversal crosses
const TAKEUP: f64 = 160.0; // ″ the motor adds on a reversal
const TRAVEL: f64 = 360.0; // ″ a move travels (0.1°)

/// A run log built event by event, in the runner's format.
struct Log {
    lines: Vec<String>,
    t: i64,
    position: [f64; 2],
    id: u64,
}

impl Log {
    fn new(anti_backlash: Option<[u8; 4]>, hardware: bool) -> Self {
        let mut celestron = json!({ "reverse_altitude": false, "reverse_azimuth": false });
        if let Some(ab) = anti_backlash {
            celestron["anti_backlash"] = json!(ab);
        }
        let mut log = Self {
            lines: Vec::new(),
            t: 1_000_000_000,
            position: [10.0, 0.0],
            id: 0,
        };
        log.push(json!({ "event": "config", "hardware": hardware, "config": { "celestron": celestron } }));
        log.idle(2.0, 260);
        log
    }

    fn push(&mut self, mut e: serde_json::Value) {
        e["t_ns"] = json!(self.t);
        self.lines.push(e.to_string());
    }

    /// Position reads every `every_ms` for `seconds`.
    fn idle(&mut self, seconds: f64, every_ms: i64) {
        let end = self.t + (seconds * 1e9) as i64;
        while self.t < end {
            self.t += every_ms * 1_000_000;
            let p = self.position;
            self.push(json!({ "event": "mount_position", "deg": p }));
        }
    }

    /// A keypad move whose encoder and phone travel are given (″, along
    /// the move), in the current nested format.
    fn keypad(&mut self, axis: &str, sign: i8, encoder: f64, phone: f64, fault: Option<&str>) {
        self.id += 1;
        let i = usize::from(axis == "altitude");
        let request = json!({ "move": {
            "axis": axis,
            "direction": if sign > 0 { "positive" } else { "negative" },
            "duration_ms": 1500, "fixed_rate": 5, "rate_deg_s": 0.0717,
            "request_id": format!("operator-{}", self.id),
        }});
        let requested = self.t;
        self.push(json!({ "event": "request", "request": request["move"] }));
        let tx = requested + 100_000_000;
        let stop = tx + 1_500_000_000;
        let done = stop + 500_000_000;
        self.t = tx;
        self.push(json!({ "event": "serial", "outcome": "ok", "sent_ns": tx, "reply_ns": tx + 40_000_000 }));
        self.position[i] += f64::from(sign) * encoder / 3600.0;
        self.t = done;
        let last = if fault.is_some() {
            "cancelled"
        } else {
            "completed"
        };
        self.push(json!({ "event": "record", "record": {
            "command_id": self.id,
            "commanded_deg": f64::from(sign) * 0.1075,
            "observed_deg": f64::from(sign) * phone / 3600.0,
            "fault": fault,
            "goto": null,
            "reason": null,
            "request": request,
            "stages": [["requested", requested], ["transmitted", tx], ["acknowledged", tx + 40_000_000],
                       ["stop_sent", stop], [last, done]],
        }}));
        self.idle(4.0, 260);
    }

    /// A clean move: reversals cross the slack with the motor's take-up.
    fn clean(&mut self, axis: &str, sign: i8, reversal: bool) {
        let (enc, phone) = if reversal {
            (TRAVEL + TAKEUP, TRAVEL + TAKEUP - SLACK)
        } else {
            (TRAVEL, TRAVEL)
        };
        self.keypad(axis, sign, enc, phone, None);
    }

    fn done(self, name: &str) -> RunLog {
        RunLog {
            name: name.into(),
            text: self.lines.join("\n") + "\n",
        }
    }
}

/// `+ + − − + + − −` on azimuth: the first move's history is unknown, then
/// reversals and repeats alternate.
fn sweep(anti_backlash: u8, name: &str) -> RunLog {
    let mut log = Log::new(Some([anti_backlash, anti_backlash, 20, 20]), true);
    let mut last = None;
    for sign in [1, 1, -1, -1, 1, 1, -1, -1, 1, 1] {
        log.clean("azimuth", sign, last.is_some_and(|l| l != sign));
        last = Some(sign);
    }
    log.done(name)
}

/// Like `sweep`, but the motor's take-up grows with the setting (4″ per
/// step), so reversals cross zero error at 150 / 4 = 37.5.
fn graded(anti_backlash: u8, name: &str) -> RunLog {
    let takeup = 4.0 * f64::from(anti_backlash);
    let mut log = Log::new(Some([anti_backlash, anti_backlash, 20, 20]), true);
    let mut last = None;
    for sign in [1, 1, -1, -1, 1, 1, -1, -1, 1, 1] {
        let reversal = last.is_some_and(|l| l != sign);
        let (enc, phone) = if reversal {
            (TRAVEL + takeup, TRAVEL + takeup - SLACK)
        } else {
            (TRAVEL, TRAVEL)
        };
        log.keypad("azimuth", sign, enc, phone, None);
        last = Some(sign);
    }
    log.done(name)
}

fn analyze(logs: &[RunLog]) -> mount::MountAnalysis {
    mount::analyze(logs, None, &MountConfig::default_config(), "test")
}

#[test]
fn known_takeup_over_correction_and_slack_are_recovered() {
    let a = analyze(&[sweep(40, "run-1")]);
    assert_eq!(a.groups.len(), 1);
    let g = &a.groups[0];
    assert_eq!(g.anti_backlash, 40);
    assert_eq!(g.label, "keypad r5, 1.5 s");
    // 10 moves: the first unknown, then 4 reversals and 5 repeats.
    assert_eq!(g.reversals.as_ref().unwrap().n, 4);
    assert_eq!(g.repeats.as_ref().unwrap().n, 5);
    let close = |v: f64, want: f64| (v - want).abs() < 1e-6;
    assert!(close(g.takeup.unwrap().value, TAKEUP), "{:?}", g.takeup);
    assert!(close(g.over_correction.unwrap().value, TAKEUP - SLACK));
    assert!(close(g.slack.unwrap().value, SLACK));
    assert_eq!(a.moves[0].history, History::Unknown);
    assert_eq!(a.moves[1].history, History::Repeat);
    assert_eq!(a.moves[2].history, History::Reversal);
}

#[test]
fn the_recommendation_is_the_setting_with_the_least_reversal_error() {
    let a = analyze(&[graded(30, "a"), graded(40, "b"), graded(60, "c")]);
    let r = &a.recommendations[0];
    assert_eq!(r.keypad.kinds, ["keypad r5, 1.5 s"]);
    // Errors: 30 → −30″, 40 → +10″, 60 → +90″.
    assert_eq!(r.keypad.best, Some(40));
    assert_eq!(r.keypad.scores.len(), 3);
    assert_eq!(r.configured, Some(60), "from the last run");
    assert_eq!(r.timed.best, None);
    // Altitude has no moves: nothing to recommend.
    assert_eq!(a.recommendations[1].keypad.best, None);
    let md = &render(&[graded(30, "a"), graded(40, "b"), graded(60, "c")])
        .into_iter()
        .find(|(n, _)| n == "report.md")
        .unwrap()
        .1;
    assert!(md.contains("| azimuth | **40** | 60 | – |"), "{md}");
    assert!(md.contains("The last run used a different setting"));
    let order = [
        "## Method and runs",
        "## What we know about this mount",
        "## Recommended anti-backlash",
        "## Performance",
        "## Supporting evidence",
    ];
    let at: Vec<usize> = order.iter().map(|h| md.find(h).unwrap()).collect();
    assert!(at.windows(2).all(|w| w[0] < w[1]), "sections in order");
}

#[test]
fn the_facts_section_states_scale_applicability_and_discovery() {
    let discovery = mount::DiscoveryLog {
        name: "disc".into(),
        text: serde_json::json!({
            "simulated": false,
            "identity": { "controller_version": "1.22", "model": "22 (NexStar Evolution)", "motor_versions": ["7.17", "7.17"] },
            "connection": { "usb": { "manufacturer": "Prolific", "product": "Bridge" }, "settings": "9600 baud, 8N1" },
            "position_latency": { "median_ms": 85.5 },
            "exchanges": [
                { "query": "azimuth backlash, positive", "outcome": "ok", "value": { "backlash": 40 } },
                { "query": "azimuth backlash, negative", "outcome": "ok", "value": { "backlash": 40 } },
                { "query": "altitude backlash, positive", "outcome": "ok", "value": { "backlash": 20 } },
                { "query": "altitude backlash, negative", "outcome": "ok", "value": { "backlash": 20 } },
                { "query": "azimuth goto approach", "outcome": "ok", "value": { "approach": "positive" } },
                { "query": "altitude goto approach", "outcome": "ok", "value": { "approach": "positive" } },
                { "query": "azimuth at index marker?", "outcome": "malformed", "value": null }
            ]
        })
        .to_string(),
    };
    let logs = [graded(30, "a"), graded(40, "b"), graded(60, "c")];
    let a = mount::analyze(
        &logs,
        Some(&discovery),
        &MountConfig::default_config(),
        "test",
    );
    let d = a.discovery.as_ref().unwrap();
    assert_eq!(d.anti_backlash, Some([40, 40, 20, 20]));
    assert_eq!(d.azimuth_index.as_deref(), Some("no answer"));
    // Every repeat travels exactly what the encoder says.
    assert!((a.scale[0].ratio.value - 1.0).abs() < 1e-12);
    // Take-up 4″ per step: shown at the recommended 40, +160″.
    let k = &a.applies[0];
    assert_eq!((k.commands.as_str(), k.anti_backlash), ("keypad r5", 40));
    assert_eq!(k.acts, mount::Acts::Yes);
    let md = &mount_report::render(&a)
        .into_iter()
        .find(|(n, _)| n == "report.md")
        .unwrap()
        .1;
    for want in [
        "model 22 (NexStar Evolution); hand controller 1.22",
        "anti-backlash azimuth +40 −40, altitude +20 −20 when read",
        "46,603 units per degree",
        "1 mm is 9,369 units",
        "| Keypad rate 5 (arrow keys) | **yes** (+160″ at 40) | – |",
        "**Stopping a move:**",
    ] {
        assert!(md.contains(want), "missing {want:?}: {md}");
    }
}

#[test]
fn groups_split_by_anti_backlash_across_runs() {
    let a = analyze(&[sweep(60, "run-2"), sweep(40, "run-1")]);
    let settings: Vec<u8> = a.groups.iter().map(|g| g.anti_backlash).collect();
    assert_eq!(settings, [40, 60]);
    // Runs are read in name order.
    assert_eq!(a.runs[0].name, "run-1");
}

#[test]
fn a_faulted_move_is_left_out_and_breaks_the_history() {
    let mut log = Log::new(Some([40; 4]), true);
    log.clean("azimuth", 1, false);
    log.clean("azimuth", 1, false);
    log.keypad("azimuth", -1, TRAVEL, TRAVEL, Some("unexpected_motion"));
    log.clean("azimuth", -1, false);
    let a = analyze(&[log.done("run")]);
    assert_eq!(a.moves[2].fault.as_deref(), Some("unexpected_motion"));
    // After the fault nothing is known about the gears.
    assert_eq!(a.moves[3].history, History::Unknown);
    assert_eq!(a.groups[0].repeats.as_ref().unwrap().n, 1);
    assert!(a.groups[0].reversals.is_none());
}

#[test]
fn a_disturbed_move_is_flagged_and_left_out() {
    let mut log = Log::new(Some([40; 4]), true);
    log.clean("azimuth", 1, false);
    for i in 0..6 {
        // Small, realistic scatter, then one move a footstep spoiled.
        let phone = if i == 3 {
            TRAVEL + 120.0
        } else {
            TRAVEL + f64::from(i % 3) * 4.0
        };
        log.keypad("azimuth", 1, TRAVEL, phone, None);
    }
    let a = analyze(&[log.done("run")]);
    let disturbed: Vec<_> = a.moves.iter().filter(|m| m.disturbed).collect();
    assert_eq!(disturbed.len(), 1);
    assert_eq!(disturbed[0].command_id, 5);
    assert_eq!(a.groups[0].repeats.as_ref().unwrap().n, 5);
}

#[test]
fn old_logs_are_read_and_their_anti_backlash_is_assumed_zero() {
    let mut log = Log::new(None, true);
    log.clean("altitude", 1, false);
    // The first logs had a flat request without `move` or a keypad rate.
    let text = log
        .done("old")
        .text
        .replace(
            r#""request":{"move":{"axis":"altitude","direction":"positive","duration_ms":1500,"fixed_rate":5,"rate_deg_s":0.0717,"request_id":"operator-1"}}"#,
            r#""request":{"axis":"altitude","direction":"positive","duration_ms":1000,"rate_deg_s":0.2,"request_id":"operator-1"}"#,
        );
    let a = analyze(&[RunLog {
        name: "old".into(),
        text,
    }]);
    let m = &a.moves[0];
    assert!(m.anti_backlash_assumed);
    assert_eq!(m.anti_backlash, 0);
    assert_eq!(
        m.kind,
        Kind::Timed {
            rate_deg_s: 0.2,
            duration_ms: 1000
        }
    );
    assert!((m.encoder_arcsec.unwrap() - TRAVEL).abs() < 1e-6);
}

#[test]
fn simulated_runs_are_skipped() {
    let mut log = Log::new(Some([40; 4]), false);
    log.clean("azimuth", 1, false);
    let a = analyze(&[log.done("sim")]);
    assert!(a.moves.is_empty());
    assert_eq!(a.runs[0].hardware, Some(false));
}

#[test]
fn keypad_speed_comes_from_repeats() {
    let a = analyze(&[sweep(40, "run")]);
    let s = &a.speeds[0];
    assert_eq!(s.rate, 5);
    assert!((s.median_deg_s - TRAVEL / 3600.0 / 1.5).abs() < 1e-9);
}

#[test]
fn idle_read_stalls_are_counted_and_commands_in_flight_are_not() {
    let mut log = Log::new(Some([40; 4]), true);
    log.idle(1.0, 800); // one stall-length gap pattern while idle
    log.clean("azimuth", 1, false); // a 1.6 s gap while the move runs: not idle
    let a = analyze(&[log.done("run")]);
    let l = &a.links[0];
    assert_eq!(l.read_stalls, 2);
    assert_eq!(l.exchanges, 1);
    assert_eq!(l.median_ms, Some(40.0));
}

#[test]
fn reports_are_byte_identical_and_name_their_inputs() {
    let logs = [sweep(40, "run-1"), sweep(60, "run-2")];
    let a = render(&logs);
    let b = render(&logs);
    assert_eq!(a, b);
    let names: Vec<&str> = a.iter().map(|(n, _)| n.as_str()).collect();
    for f in [
        "report.md",
        "report.html",
        "metrics.json",
        "moves.csv",
        "groups.csv",
        "over_correction_azimuth.svg",
        "takeup_azimuth.svg",
        "moves_azimuth.svg",
        "keypad_speeds.svg",
        "latency.svg",
        "performance.svg",
    ] {
        assert!(names.contains(&f), "missing {f}: {names:?}");
    }
    let md = &a.iter().find(|(n, _)| n == "report.md").unwrap().1;
    let sha = &mount::analyze(&logs, None, &MountConfig::default_config(), "test").runs[0].sha256;
    assert!(
        md.contains(&sha[..12]),
        "the report names each log's SHA-256"
    );
    assert!(
        md.contains("| keypad r5, 1.5 s | 40 | 5 / 4 | +160 ± <1″ | +10 ± <1″ | +150 ± <1″ |"),
        "{md}"
    );
}

fn render(logs: &[RunLog]) -> Vec<(String, String)> {
    mount_report::render(&mount::analyze(
        logs,
        None,
        &MountConfig::default_config(),
        "test",
    ))
}
