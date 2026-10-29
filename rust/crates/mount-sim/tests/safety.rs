//! The simulator safety suite (plan Prompt 6, ADR 0005): every injected
//! fault must stop the mount, or, where the mount cannot be stopped, latch
//! and keep telling the operator to cut power. Hardware code may not exist
//! until this suite passes.

use cwb_mount_core::{
    Action, Axis, Direction, FaultKind, MountCommand, MountState, MoveRequest, Stage,
};
use cwb_mount_sim::{
    SimFaults,
    harness::{Op, Scenario, Trace, run},
};

const MS: i64 = 1_000_000;

fn request(id: &str, axis: Axis, direction: Direction, rate: f64, ms: u64) -> MoveRequest {
    MoveRequest {
        request_id: id.into(),
        axis,
        direction,
        rate_deg_s: rate,
        duration_ms: ms,
    }
}

/// Connect at 100 ms, arm at 300 ms, then a 1 s azimuth move at 0.5 °/s at 500 ms.
fn one_move(faults: SimFaults) -> Scenario {
    Scenario {
        faults,
        script: vec![
            (100, Op::Connect),
            (300, Op::Arm),
            (
                500,
                Op::Move(request(
                    "m1",
                    Axis::Azimuth,
                    Direction::Positive,
                    0.5,
                    1_000,
                )),
            ),
        ],
        ..Scenario::default()
    }
}

/// `n` azimuth steps of 0.08 °/s for 1.2 s (0.096° each), every 2 s from
/// 500 ms. At 0.08 °/s each step is below the IMU's motion threshold.
fn small_steps(faults: SimFaults, n: u64) -> Scenario {
    let mut script = vec![(100, Op::Connect), (300, Op::Arm)];
    for i in 0..n {
        script.push((
            500 + i * 2_000,
            Op::Move(request(
                &format!("s{i}"),
                Axis::Azimuth,
                Direction::Positive,
                0.08,
                1_200,
            )),
        ));
    }
    Scenario {
        faults,
        script,
        run_ms: 1_000 + n * 2_000,
        ..Scenario::default()
    }
}

fn only_fault(trace: &Trace) -> FaultKind {
    assert!(!trace.faults.is_empty(), "expected a fault; none latched");
    trace.faults[0].kind
}

/// Every fault's first action is StopAll, and the session ends latched with
/// no motion command after the fault.
fn assert_stopped_and_latched(trace: &Trace) {
    assert_eq!(trace.final_state, Some(MountState::FaultLatched));
    for (t, actions) in &trace.fault_actions {
        assert_eq!(
            actions.first(),
            Some(&Action::Send(MountCommand::StopAll)),
            "fault at {t} did not stop first: {actions:?}"
        );
    }
    let fault_at = trace.first_fault_ns().unwrap();
    assert!(
        !trace
            .sent
            .iter()
            .any(|(t, c)| *t > fault_at && matches!(c, MountCommand::Move { .. })),
        "a motion command was sent after the fault"
    );
}

#[test]
fn a_normal_move_completes_and_rearms() {
    let trace = run(&one_move(SimFaults::default()));
    assert!(trace.faults.is_empty(), "{:?}", trace.faults);
    assert_eq!(trace.final_state, Some(MountState::Armed));
    let record = &trace.records[0];
    let stages: Vec<Stage> = record.stages.iter().map(|s| s.0).collect();
    assert_eq!(
        stages,
        [
            Stage::Requested,
            Stage::Transmitted,
            Stage::Acknowledged,
            Stage::StopSent,
            Stage::Completed
        ]
    );
    let travel = trace.travel_after(0);
    assert!(
        (travel[0] - 0.5).abs() < 0.03,
        "azimuth travel {}",
        travel[0]
    );
    assert!(travel[1].abs() < 1e-9);
    assert!(trace.is_still_at_end());
    assert!((record.commanded_deg.unwrap() - 0.5).abs() < 1e-9);
    assert!((record.observed_deg.unwrap() - 0.5).abs() < 0.03);
    // The stop was sent when the 1 s lease ended.
    let stop_at = record
        .stages
        .iter()
        .find(|s| s.0 == Stage::StopSent)
        .unwrap()
        .1;
    assert_eq!(stop_at, 1_500 * MS);
}

#[test]
fn a_late_acknowledgement_stops_and_latches() {
    let trace = run(&one_move(SimFaults {
        ack_delay_ms: 1_000,
        ..SimFaults::default()
    }));
    assert_eq!(only_fault(&trace), FaultKind::AcknowledgementMissing);
    assert_stopped_and_latched(&trace);
    assert!(trace.is_still_at_end());
    assert_eq!(trace.records[0].last_stage(), Stage::TimedOut);
    // Detected at the 300 ms deadline, not at the end of the lease.
    assert!(trace.first_fault_ns().unwrap() <= 810 * MS);
}

#[test]
fn a_missing_acknowledgement_stops_and_latches() {
    let trace = run(&one_move(SimFaults {
        drop_acks: true,
        ..SimFaults::default()
    }));
    assert_eq!(only_fault(&trace), FaultKind::AcknowledgementMissing);
    assert_stopped_and_latched(&trace);
    assert!(trace.is_still_at_end());
}

#[test]
fn an_ignored_stop_latches_and_keeps_telling_the_operator_to_cut_power() {
    let trace = run(&one_move(SimFaults {
        ignore_stop: true,
        ..SimFaults::default()
    }));
    // Travel past the commanded 0.5° by the tolerance gives it away about
    // 0.5 s after the stop, before the 1.5 s stop deadline.
    assert_eq!(only_fault(&trace), FaultKind::UnexpectedMotion);
    let after_stop = trace.first_fault_ns().unwrap() - 1_500 * MS;
    assert!(after_stop < 700 * MS, "caught {after_stop} ns after the stop");
    assert_stopped_and_latched(&trace);
    // The software can't stop this mount: it keeps re-sending stops and alerting.
    assert!(!trace.is_still_at_end());
    let stops_after = trace
        .sent
        .iter()
        .filter(|(t, c)| *t > trace.first_fault_ns().unwrap() && *c == MountCommand::StopAll)
        .count();
    assert!(stops_after >= 5, "only {stops_after} stops re-sent");
    let power_alerts = trace
        .alerts
        .iter()
        .filter(|(_, a)| a.contains("cut mount power"))
        .count();
    assert!(power_alerts >= 5);
}

#[test]
fn a_silent_imu_after_an_ignored_stop_still_warns_the_operator() {
    // Found by the invariant search: with the IMU gone, nothing shows the
    // mount moving, but nothing shows it stopped either.
    let trace = run(&one_move(SimFaults {
        ignore_stop: true,
        imu_stops_at_ms: Some(650),
        ..SimFaults::default()
    }));
    assert_stopped_and_latched(&trace);
    let warnings = trace
        .alerts
        .iter()
        .filter(|(_, a)| a.contains("can't be confirmed") && a.contains("cut mount power"))
        .count();
    assert!(warnings >= 5, "only {warnings} warnings");
}

#[test]
fn motion_opposite_to_the_command_stops_within_a_fraction_of_a_degree() {
    let trace = run(&one_move(SimFaults {
        reverse: true,
        ..SimFaults::default()
    }));
    assert_eq!(only_fault(&trace), FaultKind::OppositeMotion);
    assert_stopped_and_latched(&trace);
    assert!(trace.is_still_at_end());
    let travel = trace.travel_after(0)[0];
    assert!(travel < 0.0 && travel > -0.15, "wrong-way travel {travel}°");
}

#[test]
fn small_steps_the_imu_cant_see_one_by_one_add_up_and_are_confirmed() {
    let trace = run(&small_steps(SimFaults::default(), 12));
    assert!(trace.faults.is_empty(), "{:?}", trace.faults);
    assert_eq!(trace.final_state, Some(MountState::Armed));
    assert_eq!(trace.moves_sent(), 12);
    for r in &trace.records {
        assert_eq!(r.last_stage(), Stage::Completed, "{r:?}");
        assert!((r.commanded_deg.unwrap() - 0.096).abs() < 1e-9);
        assert!((r.observed_deg.unwrap() - 0.096).abs() < 0.01, "{r:?}");
    }
    let travel = trace.travel_after(0)[0];
    assert!((travel - 1.152).abs() < 0.02, "azimuth travel {travel}");
}

#[test]
fn a_stalled_axis_latches_once_commanded_travel_adds_up() {
    let trace = run(&small_steps(
        SimFaults {
            stall: true,
            ..SimFaults::default()
        },
        12,
    ));
    // Ten unseen steps are fine; the eleventh brings the tally past 1°.
    assert_eq!(only_fault(&trace), FaultKind::Stall);
    assert_eq!(trace.moves_sent(), 11);
    assert!(trace.faults[0].detail.contains("+1.056° commanded"));
    assert_stopped_and_latched(&trace);
    assert!(trace.is_still_at_end());
}

#[test]
fn slow_motion_the_wrong_way_latches_once_travel_adds_up() {
    // Too slow for the rate check; the travel check catches it.
    let trace = run(&small_steps(
        SimFaults {
            reverse: true,
            ..SimFaults::default()
        },
        12,
    ));
    assert_eq!(only_fault(&trace), FaultKind::OppositeMotion);
    assert_eq!(trace.moves_sent(), 11);
    assert_stopped_and_latched(&trace);
    let travel = trace.travel_after(0)[0];
    assert!(travel < 0.0 && travel > -1.1, "wrong-way travel {travel}°");
}

#[test]
fn a_slow_creep_after_an_ignored_stop_is_caught_by_travel() {
    // 0.03 °/s is below the still threshold: the rates alone would call the
    // mount stopped. Travel beyond the commanded 0.03° gives it away.
    let mut scenario = small_steps(
        SimFaults {
            ignore_stop: true,
            ..SimFaults::default()
        },
        0,
    );
    scenario.script.push((
        500,
        Op::Move(request(
            "creep",
            Axis::Azimuth,
            Direction::Positive,
            0.03,
            1_000,
        )),
    ));
    scenario.run_ms = 20_000;
    let trace = run(&scenario);
    assert_eq!(only_fault(&trace), FaultKind::UnexpectedMotion);
    assert_eq!(trace.records[0].last_stage(), Stage::Completed);
    let fault_at = trace.first_fault_ns().unwrap();
    let at_fault = trace.motion.iter().find(|m| m.0 >= fault_at).unwrap().1[0];
    assert!(
        at_fault < 0.03 + 0.25 + 0.01,
        "crept {at_fault}° before the fault"
    );
    assert!(
        trace
            .alerts
            .iter()
            .any(|(t, a)| *t == fault_at && a.contains("cut mount power"))
    );
    assert_eq!(trace.final_state, Some(MountState::FaultLatched));
    // It keeps creeping, so the operator keeps being told.
    assert!(
        trace
            .alerts
            .iter()
            .any(|(t, a)| *t > fault_at && a.contains("cut mount power"))
    );
}

#[test]
fn a_large_stalled_move_latches_when_it_completes() {
    let mut scenario = one_move(SimFaults {
        stall: true,
        ..SimFaults::default()
    });
    scenario.script[2] = (
        500,
        Op::Move(request(
            "big",
            Axis::Azimuth,
            Direction::Positive,
            0.6,
            2_000,
        )),
    );
    let trace = run(&scenario);
    assert_eq!(only_fault(&trace), FaultKind::Stall);
    assert_eq!(trace.records[0].last_stage(), Stage::Completed);
    assert_stopped_and_latched(&trace);
    assert!(trace.is_still_at_end());
}

#[test]
fn overspeed_stops_and_latches() {
    let trace = run(&one_move(SimFaults {
        speed_factor: 3.0,
        ..SimFaults::default()
    }));
    assert_eq!(only_fault(&trace), FaultKind::Overspeed);
    assert_stopped_and_latched(&trace);
    assert!(trace.is_still_at_end());
    // Caught within a third of a second, before the runaway axis has gone
    // further than the 0.5° the command would have moved in total.
    assert!(trace.first_fault_ns().unwrap() <= 850 * MS);
    assert!(trace.travel_after(0)[0] < 0.5);
}

#[test]
fn a_lost_link_latches_and_tells_the_operator_to_cut_power() {
    // Worst case: the link drops mid-move and the mount keeps turning.
    let trace = run(&one_move(SimFaults {
        disconnect_at_ms: Some(900),
        keep_moving_when_disconnected: true,
        ..SimFaults::default()
    }));
    assert_eq!(only_fault(&trace), FaultKind::TransportLost);
    assert_eq!(
        trace.faults.len(),
        1,
        "failed re-sends must not stack faults"
    );
    assert_stopped_and_latched(&trace);
    assert!(
        trace
            .alerts
            .iter()
            .any(|(_, a)| a.contains("cut mount power"))
    );
    assert_eq!(trace.records[0].last_stage(), Stage::Unknown);
    assert!(
        !trace.is_still_at_end(),
        "the simulated mount keeps turning"
    );

    // A mount that stops by itself when the link drops ends still.
    let trace = run(&one_move(SimFaults {
        disconnect_at_ms: Some(900),
        keep_moving_when_disconnected: false,
        ..SimFaults::default()
    }));
    assert_eq!(only_fault(&trace), FaultKind::TransportLost);
    assert!(trace.is_still_at_end());
}

#[test]
fn a_silent_imu_stops_motion() {
    let mut scenario = one_move(SimFaults {
        imu_stops_at_ms: Some(700),
        ..SimFaults::default()
    });
    scenario.script[2].1 = Op::Move(request(
        "m1",
        Axis::Azimuth,
        Direction::Positive,
        0.5,
        2_000,
    ));
    let trace = run(&scenario);
    assert_eq!(only_fault(&trace), FaultKind::StaleImu);
    assert_stopped_and_latched(&trace);
    assert!(trace.is_still_at_end());
    assert_eq!(trace.records[0].last_stage(), Stage::Unknown);
    // Last sample at 690 ms; stale once it is more than 1 s old.
    let at = trace.first_fault_ns().unwrap();
    assert!((1_690 * MS..=1_700 * MS).contains(&at), "{at}");
}

#[test]
fn a_duplicate_request_is_refused_not_resent() {
    let mut scenario = one_move(SimFaults::default());
    let again = request("m1", Axis::Azimuth, Direction::Positive, 0.5, 1_000);
    scenario.script.push((600, Op::Move(again.clone())));
    scenario.script.push((4_000, Op::Move(again)));
    let trace = run(&scenario);
    assert!(trace.faults.is_empty());
    assert_eq!(trace.moves_sent(), 1);
    assert_eq!(
        trace
            .refusals
            .iter()
            .filter(|(_, r)| r.contains("duplicate"))
            .count(),
        2
    );
    assert_eq!(trace.final_state, Some(MountState::Armed));
}

#[test]
fn process_shutdown_mid_move_stops_first() {
    let mut scenario = one_move(SimFaults::default());
    scenario.script.push((900, Op::Shutdown));
    let trace = run(&scenario);
    assert_eq!(only_fault(&trace), FaultKind::ProcessShutdown);
    assert_stopped_and_latched(&trace);
    assert!(trace.is_still_at_end());
    assert_eq!(trace.first_fault_ns(), Some(900 * MS));
}

#[test]
fn emergency_stop_mid_move_stops_and_latches() {
    let mut scenario = one_move(SimFaults::default());
    scenario.script.push((800, Op::EmergencyStop));
    let trace = run(&scenario);
    assert_eq!(only_fault(&trace), FaultKind::EmergencyStop);
    assert_stopped_and_latched(&trace);
    assert!(trace.is_still_at_end());
}

#[test]
fn an_operator_stop_ends_the_command_cleanly() {
    let mut scenario = one_move(SimFaults::default());
    scenario.script.push((800, Op::Stop));
    let trace = run(&scenario);
    assert!(trace.faults.is_empty(), "{:?}", trace.faults);
    assert_eq!(trace.records[0].last_stage(), Stage::Cancelled);
    assert_eq!(trace.final_state, Some(MountState::Armed));
}

#[test]
fn motion_while_armed_with_no_command_latches() {
    let trace = run(&Scenario {
        faults: SimFaults {
            bump: Some((Axis::Altitude, 0.5, 1_000, 1_500)),
            ..SimFaults::default()
        },
        script: vec![(100, Op::Connect), (300, Op::Arm)],
        ..Scenario::default()
    });
    assert_eq!(only_fault(&trace), FaultKind::UnexpectedMotion);
    assert_stopped_and_latched(&trace);
}

#[test]
fn leaving_the_altitude_envelope_stops() {
    let trace = run(&Scenario {
        start_altitude_deg: 84.6,
        script: vec![
            (100, Op::Connect),
            (300, Op::Arm),
            (
                500,
                Op::Move(request(
                    "up",
                    Axis::Altitude,
                    Direction::Positive,
                    1.0,
                    2_000,
                )),
            ),
        ],
        ..Scenario::default()
    });
    assert_eq!(only_fault(&trace), FaultKind::LimitBreach);
    assert_stopped_and_latched(&trace);
    assert!(trace.is_still_at_end());
    let peak = trace
        .motion
        .iter()
        .map(|m| 84.6 + m.1[1])
        .fold(f64::MIN, f64::max);
    assert!(peak < 85.2, "overshot the limit to {peak}°");
}

#[test]
fn requests_outside_the_rules_are_refused_and_recorded() {
    let trace = run(&Scenario {
        script: vec![
            (100, Op::Connect),
            (
                200,
                Op::Move(request(
                    "early",
                    Axis::Azimuth,
                    Direction::Positive,
                    0.5,
                    500,
                )),
            ),
            (300, Op::Arm),
            (
                400,
                Op::Move(request(
                    "fast",
                    Axis::Azimuth,
                    Direction::Positive,
                    5.0,
                    500,
                )),
            ),
            (
                410,
                Op::Move(request(
                    "slow",
                    Axis::Azimuth,
                    Direction::Positive,
                    0.0001,
                    500,
                )),
            ),
            (
                420,
                Op::Move(request(
                    "long",
                    Axis::Azimuth,
                    Direction::Positive,
                    0.5,
                    60_000,
                )),
            ),
            (
                500,
                Op::Move(request(
                    "ok",
                    Axis::Azimuth,
                    Direction::Positive,
                    0.5,
                    1_000,
                )),
            ),
            (
                600,
                Op::Move(request(
                    "second",
                    Axis::Altitude,
                    Direction::Positive,
                    0.5,
                    500,
                )),
            ),
        ],
        ..Scenario::default()
    });
    assert!(trace.faults.is_empty(), "{:?}", trace.faults);
    assert_eq!(trace.moves_sent(), 1);
    let reasons: Vec<&str> = trace.refusals.iter().map(|(_, r)| r.as_str()).collect();
    assert_eq!(reasons.len(), 5, "{reasons:?}");
    assert!(reasons[0].contains("not armed"));
    assert!(reasons[1].contains("rate"));
    assert!(reasons[2].contains("rate"));
    assert!(reasons[3].contains("duration"));
    assert!(reasons[4].contains("not armed (state Moving)"));
    let rejected = trace
        .records
        .iter()
        .filter(|r| r.last_stage() == Stage::Rejected)
        .count();
    assert_eq!(rejected, 5, "refused requests are recorded too");
}

#[test]
fn arming_needs_a_live_imu() {
    let trace = run(&Scenario {
        faults: SimFaults {
            imu_stops_at_ms: Some(0),
            ..SimFaults::default()
        },
        script: vec![(100, Op::Connect), (300, Op::Arm)],
        ..Scenario::default()
    });
    assert_eq!(trace.final_state, Some(MountState::ConnectedReadOnly));
    assert!(trace.refusals[0].1.contains("stale"));
}

#[test]
fn rearming_after_a_fault_is_manual_and_needs_a_still_mount() {
    let mut scenario = one_move(SimFaults::default());
    scenario.script.extend([
        (800, Op::EmergencyStop),
        (
            1_500,
            Op::Move(request(
                "too-soon",
                Axis::Azimuth,
                Direction::Positive,
                0.5,
                500,
            )),
        ),
        (2_000, Op::Reset),
        (
            2_100,
            Op::Move(request(
                "not-armed",
                Axis::Azimuth,
                Direction::Positive,
                0.5,
                500,
            )),
        ),
        (2_200, Op::Arm),
        (
            2_400,
            Op::Move(request(
                "again",
                Axis::Azimuth,
                Direction::Negative,
                0.5,
                500,
            )),
        ),
    ]);
    let trace = run(&scenario);
    assert_eq!(trace.faults.len(), 1);
    assert_eq!(trace.moves_sent(), 2);
    assert_eq!(trace.final_state, Some(MountState::Armed));
    assert_eq!(trace.records.last().unwrap().last_stage(), Stage::Completed);
    assert_eq!(trace.refusals.len(), 2);

    // A reset is refused while the mount is still moving.
    let mut stuck = one_move(SimFaults {
        ignore_stop: true,
        ..SimFaults::default()
    });
    stuck.script.push((5_000, Op::Reset));
    let trace = run(&stuck);
    assert_eq!(trace.final_state, Some(MountState::FaultLatched));
    assert!(
        trace
            .refusals
            .iter()
            .any(|(_, r)| r.contains("still moving"))
    );
}

/// Deterministic pseudo-random numbers for the invariant search.
struct Lcg(u64);

impl Lcg {
    fn next(&mut self) -> u64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        self.0 >> 33
    }

    fn chance(&mut self, percent: u64) -> bool {
        self.next() % 100 < percent
    }
}

#[test]
fn safety_invariants_hold_across_random_fault_combinations() {
    for seed in 0..1_000u64 {
        let mut rng = Lcg(seed * 7_919 + 1);
        let faults = SimFaults {
            ack_delay_ms: if rng.chance(15) { 600 } else { 20 },
            drop_acks: rng.chance(10),
            ignore_stop: rng.chance(10),
            reverse: rng.chance(10),
            stall: rng.chance(10),
            speed_factor: if rng.chance(10) { 2.5 } else { 1.0 },
            disconnect_at_ms: rng.chance(10).then(|| 500 + rng.next() % 3_000),
            keep_moving_when_disconnected: rng.chance(50),
            imu_stops_at_ms: rng.chance(10).then(|| 500 + rng.next() % 3_000),
            bump: rng
                .chance(10)
                .then(|| (Axis::Altitude, 0.4, 1_000 + rng.next() % 2_000, 3_500)),
        };
        let mut script = vec![(100, Op::Connect), (300, Op::Arm)];
        let mut t = 400;
        for i in 0..8 {
            t += 100 + rng.next() % 900;
            let op = match rng.next() % 10 {
                0 => Op::Stop,
                1 => Op::Reset,
                2 => Op::Arm,
                3 if rng.chance(30) => Op::EmergencyStop,
                _ => Op::Move(request(
                    &format!("r{}", if rng.chance(10) { 0 } else { i }),
                    if rng.chance(50) {
                        Axis::Azimuth
                    } else {
                        Axis::Altitude
                    },
                    if rng.chance(50) {
                        Direction::Positive
                    } else {
                        Direction::Negative
                    },
                    if rng.chance(40) {
                        0.02 + (rng.next() % 4) as f64 * 0.02
                    } else {
                        0.3 + (rng.next() % 8) as f64 * 0.1
                    },
                    200 + rng.next() % 1_800,
                )),
            };
            script.push((t, op));
        }
        let scenario = Scenario {
            faults: faults.clone(),
            script,
            run_ms: t + 6_000,
            seed,
            ..Scenario::default()
        };
        let trace = run(&scenario);
        let ctx = format!("seed {seed}, faults {faults:?}");

        // 1. Every fault stops first.
        for (at, actions) in &trace.fault_actions {
            assert_eq!(
                actions.first(),
                Some(&Action::Send(MountCommand::StopAll)),
                "{ctx}: fault at {at} did not stop first"
            );
        }
        // 2. Motion is only ever commanded from the armed state.
        for (at, command) in &trace.sent {
            if matches!(command, MountCommand::Move { .. }) {
                let before = trace.states.iter().rev().find(|(t, _)| t < at).map(|s| s.1);
                assert_eq!(before, Some(MountState::Armed), "{ctx}: move at {at}");
            }
        }
        // 3. One command at a time, and every command reaches a final stage.
        let mut accepted: Vec<_> = trace
            .records
            .iter()
            .filter(|r| r.has(Stage::Transmitted))
            .collect();
        accepted.sort_by_key(|r| r.stages[1].1);
        for pair in accepted.windows(2) {
            let end = pair[0].stages.last().unwrap();
            assert!(end.0.is_final(), "{ctx}: {:?}", pair[0]);
            assert!(end.1 <= pair[1].stages[1].1, "{ctx}: overlapping commands");
        }
        for r in &trace.records {
            assert!(r.last_stage().is_final(), "{ctx}: left active: {r:?}");
        }
        // 4. Unless the mount can't be stopped, it ends still.
        let unstoppable = faults.ignore_stop
            || (faults.disconnect_at_ms.is_some() && faults.keep_moving_when_disconnected);
        if !unstoppable && faults.bump.is_none() {
            assert!(
                trace.is_still_at_end(),
                "{ctx}: still moving at the end: {:?}",
                trace.final_rates()
            );
        }
        // 5. A mount the software can't stop always gets the cut-power alert.
        if !trace.is_still_at_end() && trace.final_state == Some(MountState::FaultLatched) {
            assert!(
                trace
                    .alerts
                    .iter()
                    .any(|(_, a)| a.contains("cut mount power")),
                "{ctx}: moving and latched without telling the operator"
            );
        }
    }
}
