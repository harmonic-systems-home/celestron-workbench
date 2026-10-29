//! Discovery against the simulated hand controller: healthy and faulty.

use cwb_celestron_discovery::{
    HandController, discover,
    discover::{Connection, Discovery, OperatorInfo, Outcome, Status},
    fake::{FakeHandController, FakeSetup},
    query::{self, Query},
    redact_path, report, summarize,
};
use cwb_mount_core::MountQueries;

fn run(setup: FakeSetup, repeats: usize) -> (Discovery, FakeHandController) {
    let mut hc = HandController::new(FakeHandController::new(setup));
    discover(&mut hc, repeats);
    let (fake, exchanges) = hc.into_parts();
    let d = summarize(
        exchanges,
        true,
        "2026-10-29T00:00:00Z".into(),
        OperatorInfo::default(),
        Connection {
            port: "simulated".into(),
            usb: None,
            settings: "9600 8N1".into(),
        },
    );
    (d, fake)
}

fn status(d: &Discovery, name: &str) -> Status {
    d.checks
        .iter()
        .find(|c| c.name == name)
        .unwrap_or_else(|| panic!("no check {name}"))
        .status
}

#[test]
fn a_healthy_evolution_passes_and_only_catalog_bytes_are_sent() {
    let (d, fake) = run(FakeSetup::default(), 5);
    assert!(d.ready(), "{:#?}", d.checks);
    assert_eq!(status(&d, "Model"), Status::Pass);
    assert_eq!(status(&d, "Positions steady"), Status::Pass);
    assert_eq!(d.exchanges.len(), 9 + 2 * 5);
    let planned: Vec<Vec<u8>> = query::plan(5).into_iter().map(Query::bytes).collect();
    assert_eq!(fake.received, planned, "sent exactly the plan");
    assert_eq!(d.identity.model.as_deref(), Some("22 (NexStar Evolution)"));
    assert_eq!(d.identity.motor_versions[1].as_deref(), Some("7.11"));
    let [azm, alt] = d.position_spread_arcsec.unwrap();
    // Jitter of ±0x100 in 2^32 is 0.0774″ each way.
    assert!(
        (azm - 0.155).abs() < 0.01 && (alt - 0.155).abs() < 0.01,
        "{azm} {alt}"
    );
}

#[test]
fn a_motor_that_does_not_answer_is_flagged_by_the_protocol_error_byte() {
    let (d, _) = run(
        FakeSetup {
            motor_versions: [Some((7, 11)), None],
            ..FakeSetup::default()
        },
        2,
    );
    assert!(!d.ready());
    assert_eq!(status(&d, "Motor controllers"), Status::Fail);
    let e = d
        .exchanges
        .iter()
        .find(|e| e.query == "altitude motor version")
        .unwrap();
    assert_eq!(e.outcome, Outcome::DeviceNoResponse);
}

#[test]
fn a_silent_controller_times_out_everywhere_and_fails() {
    let (d, _) = run(
        FakeSetup {
            silent: true,
            ..FakeSetup::default()
        },
        2,
    );
    assert!(!d.ready());
    assert!(d.exchanges.iter().all(|e| e.outcome == Outcome::Timeout));
    for name in [
        "Link",
        "Hand controller version",
        "Model",
        "All queries answered",
    ] {
        assert_eq!(status(&d, name), Status::Fail, "{name}");
    }
}

#[test]
fn tracking_on_or_another_model_warns_without_failing() {
    let (d, _) = run(
        FakeSetup {
            tracking_mode: 1,
            model: 12,
            ..FakeSetup::default()
        },
        2,
    );
    assert!(d.ready());
    assert_eq!(status(&d, "Tracking"), Status::Warn);
    assert_eq!(status(&d, "Model"), Status::Warn);
}

#[test]
fn a_low_version_number_is_information_when_the_newer_queries_answer() {
    // The Evolution tested on 2026-10-29 reported 1.22 and answered everything.
    let (d, _) = run(
        FakeSetup {
            version: (1, 22),
            ..FakeSetup::default()
        },
        2,
    );
    assert!(d.ready(), "{:#?}", d.checks);
    assert_eq!(status(&d, "Hand controller version"), Status::Info);
}

#[test]
fn a_moving_mount_warns_that_positions_are_not_steady() {
    let (d, _) = run(
        FakeSetup {
            jitter: vec![0, 0x0100_0000],
            ..FakeSetup::default()
        },
        4,
    );
    assert_eq!(status(&d, "Positions steady"), Status::Warn);
}

#[test]
fn the_hand_controller_answers_through_the_mount_core_trait() {
    let mut hc = HandController::new(FakeHandController::new(FakeSetup::default()));
    let id = hc.identify().unwrap();
    assert_eq!(id.controller_version.as_deref(), Some("5.34"));
    let [azm, alt] = hc.axis_positions_deg().unwrap();
    assert!((azm - 0x1234_5600u32 as f64 / 2f64.powi(32) * 360.0).abs() < 1e-6);
    assert!((alt - 11.25).abs() < 1e-6);

    let mut silent = HandController::new(FakeHandController::new(FakeSetup {
        silent: true,
        ..FakeSetup::default()
    }));
    assert!(silent.identify().is_err());
    assert!(silent.axis_positions_deg().is_err());
}

#[test]
fn device_paths_lose_their_serial_numbers() {
    assert_eq!(
        redact_path("/dev/cu.usbserial-A10KZ3VB"),
        "/dev/cu.usbserial-<redacted>"
    );
    assert_eq!(
        redact_path("/dev/cu.usbmodem14101"),
        "/dev/cu.usbmodem<redacted>"
    );
    assert_eq!(
        redact_path("/dev/cu.Bluetooth-Incoming-Port"),
        "/dev/cu.Bluetooth-Incoming-Port"
    );
}

#[test]
fn the_report_is_written_and_says_what_was_not_sent() {
    let (d, _) = run(FakeSetup::default(), 3);
    let dir = tempfile::tempdir().unwrap();
    report::write(&d, dir.path()).unwrap();
    let md = std::fs::read_to_string(dir.path().join("report.md")).unwrap();
    for needle in [
        "**Simulated.**",
        "ready for operator review",
        "No motion, goto, sync, tracking, time or location command was sent",
        "## Proposed commands for the hardware adapter (not sent)",
        "`P 03 10 06 hi lo 00 00`",
        "Get Location (`w`)",
        "1154108406_nexstarcommprot.pdf",
    ] {
        assert!(md.contains(needle), "missing {needle:?}");
    }
    let trace = std::fs::read_to_string(dir.path().join("trace.ndjson")).unwrap();
    assert_eq!(trace.lines().count(), d.exchanges.len());
    let json: serde_json::Value =
        serde_json::from_str(&std::fs::read_to_string(dir.path().join("report.json")).unwrap())
            .unwrap();
    assert_eq!(json["simulated"], true);
}
