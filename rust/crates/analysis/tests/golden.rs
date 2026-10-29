//! Golden synthetic sessions with known truth (plan Prompt 5): zero motion,
//! known bias and drift, known rotations, missing data, angle wrap,
//! quaternion sign equivalence, and byte-identical reports.

use cwb_analysis::{
    Analysis, Config, analyze, config, load, math, report,
    stationary::Outcome,
    synthetic::{SESSION, Scenario, rotation},
};

const IDENTITY: [f64; 4] = [1.0, 0.0, 0.0, 0.0];

fn run(scenario: &Scenario) -> (Analysis, cwb_analysis::SessionData) {
    let conn = scenario.store();
    let data = load(&conn, SESSION, None).unwrap();
    let analysis = analyze(
        &data,
        &Config::stationary(),
        &config::sha256(config::STATIONARY),
    );
    (analysis, data)
}

fn channel<'a>(
    a: &'a Analysis,
    window: usize,
    name: &str,
) -> &'a cwb_analysis::stationary::Channel {
    a.noise
        .iter()
        .find(|n| n.window == window)
        .unwrap()
        .channels
        .iter()
        .find(|c| c.name == name)
        .unwrap()
}

fn adev(a: &Analysis, name: &str, tau: f64) -> f64 {
    let r = a.resolution.as_ref().unwrap();
    let i = r.channels.iter().position(|(n, _)| *n == name).unwrap();
    r.rows.iter().find(|row| row.tau_s == tau).unwrap().adev[i].unwrap()
}

fn close(actual: f64, expected: f64, tolerance: f64) -> bool {
    (actual - expected).abs() <= tolerance
}

#[test]
fn zero_motion_gives_one_window_and_white_noise_resolution() {
    let (a, _) = run(&Scenario {
        seconds: 120.0,
        attitude_noise_deg: 0.01,
        accel_noise_m_s2: 0.01,
        gyro_noise_rad_s: 0.001,
        poses: vec![(0.0, 120.0, IDENTITY)],
        ..Scenario::default()
    });
    assert_eq!(a.windows.len(), 1);
    let w = &a.windows[0];
    assert!(w.steady && close(w.start_s, 0.5, 0.02) && close(w.end_s, 119.49, 0.02));
    assert!(close(w.gravity_device[2], -1.0, 1e-6));
    assert!(a.moves.is_empty());
    assert_eq!(a.timing.missing_samples, 0);
    assert!(close(a.timing.streams[0].rate_hz.unwrap(), 100.0, 1e-6));

    // Attitude jitter of 0.01° per axis shows as 0.01° of tilt about each axis.
    let tilt = channel(&a, 0, "tilt_a");
    assert!(close(tilt.summary.sd, 0.01, 0.001), "{}", tilt.summary.sd);
    assert!(close(tilt.summary.mad, 0.01, 0.001));
    assert!(close(tilt.drift_per_min.unwrap(), 0.0, 1e-4));
    // 0.01 m/s² of accelerometer noise is 0.0584° of tilt.
    let accel = channel(&a, 0, "accel_tilt_b");
    assert!(
        close(accel.summary.sd, 0.0584, 0.004),
        "{}",
        accel.summary.sd
    );

    // White noise averages down as 1/√n: τ = 1 s is 100 samples.
    assert!(close(adev(&a, "tilt_a", 1.0), 0.001, 0.0002));
    // Gyro noise of 0.001 rad/s, averaged over two samples.
    assert!(close(
        adev(&a, "gyro_x", 0.02),
        0.001_f64.to_degrees() / 2f64.sqrt(),
        0.01
    ));
    let minimum = a.resolution.as_ref().unwrap().minimum[0].unwrap();
    assert!(
        minimum.0 >= 10.0,
        "white noise keeps improving: minimum at {} s",
        minimum.0
    );

    // No clock exchanges: provisionally acceptable, not failed.
    let clock = a
        .acceptance
        .iter()
        .find(|c| c.name.starts_with("clock"))
        .unwrap();
    assert_eq!(clock.outcome, Outcome::NotMeasured);
    assert!(a.decision.starts_with("provisionally"));
}

#[test]
fn gyro_bias_and_heading_drift_are_recovered() {
    let bias = [0.001, -0.002, 0.003];
    let (a, _) = run(&Scenario {
        gyro_bias_rad_s: bias,
        heading_drift_deg_per_min: 0.5,
        ..Scenario::default()
    });
    for (i, name) in ["gyro_x", "gyro_y", "gyro_z"].iter().enumerate() {
        let c = channel(&a, 0, name);
        // The fused rate also carries the 0.5°/min heading drift on Z.
        let drift = if i == 2 { 0.5 / 60.0 } else { 0.0 };
        assert!(
            close(c.summary.mean, bias[i].to_degrees() + drift, 1e-9),
            "{name}: {}",
            c.summary.mean
        );
    }
    let heading = channel(&a, 0, "heading");
    assert!(close(heading.drift_per_min.unwrap(), 0.5, 1e-6));
    assert!(close(
        channel(&a, 0, "tilt_a").drift_per_min.unwrap(),
        0.0,
        1e-9
    ));
}

#[test]
fn moves_between_poses_measure_the_known_rotations() {
    let flat = IDENTITY;
    let on_edge = math::qmul(flat, rotation([1.0, 0.0, 0.0], 90.0));
    let turned = math::qmul(rotation([0.0, 0.0, 1.0], 30.0), flat);
    let (a, _) = run(&Scenario {
        seconds: 40.0,
        poses: vec![
            (0.0, 10.0, flat),
            (13.0, 25.0, on_edge),
            (28.0, 40.0, turned),
        ],
        markers: vec![
            (5.0, "Flat".into()),
            (20.0, "Vert".into()),
            (11.5, "moving".into()),
        ],
        ..Scenario::default()
    });
    assert_eq!(a.windows.len(), 3);
    let first = &a.moves[0];
    assert!(close(first.angle_deg, 90.0, 1e-6), "{}", first.angle_deg);
    assert!(close(first.axis_device[0], 1.0, 1e-9));
    assert!(close(first.heading_deg, 0.0, 1e-6));
    assert!(close(first.gravity_change_deg, 90.0, 1e-6));
    // Raising the top edge from flat puts gravity on −Y (docs/assumptions.md, P3).
    assert!(close(a.windows[1].gravity_device[1], -1.0, 1e-9));
    let second = &a.moves[1];
    assert!(
        close(second.heading_deg, 30.0, 1e-6),
        "{}",
        second.heading_deg
    );
    assert!(close(second.gravity_change_deg, 90.0, 1e-6));

    let at = |label: &str| a.markers.iter().find(|m| m.label == label).unwrap().window;
    assert_eq!(
        (at("Flat"), at("Vert"), at("moving")),
        (Some(0), Some(1), None)
    );
}

#[test]
fn missing_samples_are_counted_split_windows_and_fail_acceptance() {
    // About one second lost at t = 10 s.
    let (a, _) = run(&Scenario {
        missing: vec![(3000, 3299)],
        ..Scenario::default()
    });
    assert_eq!(a.timing.missing_samples, 300);
    assert_eq!(a.timing.missing, vec![(3000, 3299)]);
    assert_eq!(a.timing.streams[0].long_intervals, 1);
    assert_eq!(a.windows.len(), 2, "a gap splits the still window");
    assert!(close(a.windows[0].end_s, 9.49, 0.02));
    let missing = a
        .acceptance
        .iter()
        .find(|c| c.name == "missing samples")
        .unwrap();
    assert_eq!(missing.outcome, Outcome::Fail);
    assert!(a.decision.starts_with("not accepted"));
}

#[test]
fn heading_across_the_wrap_is_continuous() {
    // Starts 0.02° short of ±180° and drifts through it.
    let start = rotation([0.0, 0.0, 1.0], 179.98);
    let (a, _) = run(&Scenario {
        poses: vec![(0.0, 60.0, start)],
        heading_drift_deg_per_min: 0.3,
        ..Scenario::default()
    });
    let heading = channel(&a, 0, "heading");
    assert!(close(heading.drift_per_min.unwrap(), 0.3, 1e-6));
    assert!(heading.summary.p95 - heading.summary.p05 < 0.3);

    let pi = std::f64::consts::PI;
    let wrapped = [pi - 0.01, pi - 0.001, -pi + 0.001, -pi + 0.01, pi - 0.001];
    let unwrapped = math::unwrap(&wrapped);
    assert!(close(unwrapped[2], pi + 0.001, 1e-12));
    assert!(close(unwrapped[3], pi + 0.01, 1e-12));
    assert!(close(unwrapped[4], pi - 0.001, 1e-12));
}

#[test]
fn quaternion_sign_does_not_change_any_result() {
    let scenario = Scenario {
        seconds: 40.0,
        attitude_noise_deg: 0.02,
        poses: vec![
            (0.0, 15.0, IDENTITY),
            (18.0, 40.0, rotation([0.3, -0.5, 0.8], 120.0)),
        ],
        ..Scenario::default()
    };
    let (plain, _) = run(&scenario);
    let (flipped, _) = run(&Scenario {
        flip_signs: true,
        ..scenario
    });
    let metrics = |a: &Analysis| {
        let mut v = serde_json::to_value(a).unwrap();
        v.as_object_mut().unwrap().remove("source");
        v
    };
    assert_eq!(metrics(&plain), metrics(&flipped));
    assert!(close(plain.moves[0].angle_deg, 120.0, 0.01));
}

#[test]
fn reports_are_byte_identical_and_complete() {
    let scenario = Scenario {
        attitude_noise_deg: 0.005,
        gyro_noise_rad_s: 0.0005,
        accel_noise_m_s2: 0.005,
        poses: vec![
            (0.0, 25.0, IDENTITY),
            (28.0, 60.0, rotation([1.0, 0.0, 0.0], 45.0)),
        ],
        markers: vec![(5.0, "start".into())],
        ..Scenario::default()
    };
    // The same stored session, loaded and analysed twice.
    let conn = scenario.store();
    let render = || {
        let data = load(&conn, SESSION, None).unwrap();
        let a = analyze(
            &data,
            &Config::stationary(),
            &config::sha256(config::STATIONARY),
        );
        (report::render(&a, &data), a)
    };
    let (first, a) = render();
    assert_eq!(first, render().0);
    let names: Vec<&str> = first.iter().map(|(n, _)| *n).collect();
    for expected in [
        "report.md",
        "report.html",
        "metrics.json",
        "windows.csv",
        "timeline.svg",
        "resolution.csv",
        "resolution_angles.svg",
        "resolution_gyro.svg",
    ] {
        assert!(names.contains(&expected), "missing {expected}");
    }
    let md = &first.iter().find(|(n, _)| *n == "report.md").unwrap().1;
    assert!(md.contains(&a.source.export_sha256));
    assert!(md.contains("stationary-v1"));
    assert!(md.contains("| 0 → 1 | 45.000°"));
}

#[test]
fn configs_are_versioned() {
    let config = Config::stationary();
    assert_eq!(config.version, config::CONFIG_VERSION);
    let newer = config::STATIONARY.replace("version = 1", "version = 2");
    assert!(Config::parse(&newer).is_err());
    let typo = config::STATIONARY.replace("trim_s", "trim_seconds");
    assert!(Config::parse(&typo).is_err());
}
