//! Gotos by axis position against the simulated mount (ADR 0014): a clean
//! goto, overshoot within and beyond the margin, a goto that never
//! finishes, one that runs fast, one the stop can't end, one that settles
//! off target, and the approach flag's two legs.

use cwb_mount_core::{
    Action, Axis, Direction, FaultKind, GotoRequest, GotoSpeed, MountCommand, MountState,
    SafetyConfig, Stage, deg_to_units, units_between, units_to_deg,
};
use cwb_mount_sim::{
    SimFaults,
    harness::{Op, Scenario, Trace, run},
};

const MS: i64 = 1_000_000;

fn goto(id: &str, axis: Axis, delta_deg: f64) -> GotoRequest {
    GotoRequest {
        request_id: id.into(),
        axis,
        delta_deg,
        speed: GotoSpeed::Slow,
        approach: None,
    }
}

/// Connect at 100 ms, arm at 300 ms, then the goto at 500 ms.
fn one_goto(request: GotoRequest, faults: SimFaults) -> Scenario {
    Scenario {
        faults,
        script: vec![(100, Op::Connect), (300, Op::Arm), (500, Op::Goto(request))],
        ..Scenario::default()
    }
}

/// Gotos up to 1°, for faults that need room to show.
fn long_gotos() -> SafetyConfig {
    SafetyConfig {
        max_goto_deg: 1.0,
        ..SafetyConfig::default()
    }
}

fn stages(trace: &Trace, i: usize) -> Vec<Stage> {
    trace.records[i].stages.iter().map(|s| s.0).collect()
}

/// The fault stopped first, and no motion was commanded after it.
fn assert_stopped_and_latched(trace: &Trace, kind: FaultKind) {
    assert_eq!(
        trace.faults.first().map(|f| f.kind),
        Some(kind),
        "{:?}",
        trace.faults
    );
    assert_eq!(trace.final_state, Some(MountState::FaultLatched));
    for (t, actions) in &trace.fault_actions {
        assert_eq!(
            actions.first(),
            Some(&Action::Send(MountCommand::StopAll)),
            "fault at {t} did not stop first"
        );
    }
    let fault_at = trace.first_fault_ns().unwrap();
    assert!(
        !trace
            .sent
            .iter()
            .any(|(t, c)| *t > fault_at && !c.is_stop()),
        "motion commanded after the fault"
    );
}

#[test]
fn a_clean_goto_arrives_settles_stops_and_rearms() {
    let trace = run(&one_goto(
        goto("g1", Axis::Azimuth, 0.03),
        SimFaults::default(),
    ));
    assert!(trace.faults.is_empty(), "{:?}", trace.faults);
    assert_eq!(trace.final_state, Some(MountState::Armed));
    assert_eq!(
        stages(&trace, 0),
        [
            Stage::Requested,
            Stage::Transmitted,
            Stage::Acknowledged,
            Stage::StopSent,
            Stage::Completed
        ]
    );
    let gotos = trace.gotos_sent();
    assert_eq!(gotos.len(), 1);
    let MountCommand::Goto { target, speed, .. } = gotos[0] else {
        unreachable!()
    };
    assert_eq!(target, deg_to_units(0.03) as u32);
    assert_eq!(speed, GotoSpeed::Slow);

    let record = &trace.records[0];
    let g = record.goto.as_ref().unwrap();
    assert_eq!(g.start, 0);
    assert_eq!(g.target, target);
    assert_eq!(g.legs, [target]);
    assert_eq!(g.last, Some(target));
    assert_eq!(g.error_units, Some(0));
    assert_eq!((g.overshoot_units, g.crossings), (0, 0));
    // 0.03° at 0.1 °/s, then held still 300 ms between reads 90 ms apart.
    let settle = g.settle_ms.unwrap();
    assert!((300.0..1_200.0).contains(&settle), "settled in {settle} ms");
    assert!((record.commanded_deg.unwrap() - units_to_deg(i64::from(target))).abs() < 1e-12);
    assert!((record.observed_deg.unwrap() - 0.03).abs() < 0.01);
    assert!((trace.travel_after(0)[0] - 0.03).abs() < 1e-4);
    assert!(trace.is_still_at_end());
    // Only once the axis settled was the stop sent.
    let stop_at = record.stages[3].1;
    assert!(stop_at > record.stages[2].1 + 300 * MS);
}

#[test]
fn a_negative_goto_across_zero_wraps() {
    let trace = run(&one_goto(
        goto("g1", Axis::Azimuth, -0.03),
        SimFaults::default(),
    ));
    assert!(trace.faults.is_empty(), "{:?}", trace.faults);
    let g = trace.records[0].goto.as_ref().unwrap();
    assert_eq!(g.target, (1 << 24) - deg_to_units(0.03) as u32);
    assert_eq!(g.error_units, Some(0));
    assert!((trace.travel_after(0)[0] + 0.03).abs() < 1e-4);
    assert!(trace.records[0].commanded_deg.unwrap() < 0.0);
}

#[test]
fn an_overshoot_within_the_margin_completes_and_is_recorded() {
    let trace = run(&one_goto(
        goto("g1", Axis::Azimuth, 0.03),
        SimFaults {
            goto_overshoot_deg: 0.02,
            ..SimFaults::default()
        },
    ));
    assert!(trace.faults.is_empty(), "{:?}", trace.faults);
    assert_eq!(trace.final_state, Some(MountState::Armed));
    let g = trace.records[0].goto.as_ref().unwrap();
    assert_eq!(g.error_units, Some(0));
    assert!(
        g.overshoot_units > 0 && g.overshoot_units <= deg_to_units(0.02),
        "{g:?}"
    );
    assert_eq!(g.crossings, 1, "{g:?}");
}

#[test]
fn an_overshoot_beyond_the_margin_latches() {
    let trace = run(&one_goto(
        goto("g1", Axis::Azimuth, 0.03),
        SimFaults {
            goto_overshoot_deg: 0.3,
            ..SimFaults::default()
        },
    ));
    assert_stopped_and_latched(&trace, FaultKind::Overshoot);
    let record = &trace.records[0];
    assert_eq!(record.last_stage(), Stage::Cancelled);
    assert!(record.goto.as_ref().unwrap().overshoot_units > deg_to_units(0.15));
    // Stopped soon after passing the margin, well short of the 0.3° aim.
    assert!(
        trace.travel_after(0)[0] < 0.03 + 0.2,
        "{:?}",
        trace.travel_after(0)
    );
    assert!(trace.is_still_at_end());
}

#[test]
fn a_goto_that_never_finishes_times_out() {
    let trace = run(&one_goto(
        goto("g1", Axis::Azimuth, 0.03),
        SimFaults {
            stall: true,
            ..SimFaults::default()
        },
    ));
    assert_stopped_and_latched(&trace, FaultKind::CommandTimeout);
    // 0.03° at the 0.05 °/s floor plus 2 s to settle, from the send at 500 ms.
    let at = trace.first_fault_ns().unwrap();
    assert!((3_100 * MS..3_200 * MS).contains(&at), "{at}");
    assert_eq!(trace.records[0].last_stage(), Stage::TimedOut);
}

#[test]
fn a_goto_that_runs_fast_latches_overspeed() {
    let trace = run(&Scenario {
        config: SafetyConfig {
            max_goto_rate_deg_s: 0.2,
            ..long_gotos()
        },
        ..one_goto(
            goto("g1", Axis::Azimuth, 0.5),
            SimFaults {
                speed_factor: 5.0,
                ..SimFaults::default()
            },
        )
    });
    assert_stopped_and_latched(&trace, FaultKind::Overspeed);
    assert!(trace.is_still_at_end());
}

#[test]
fn a_goto_on_a_reversed_axis_is_caught() {
    // The goto's target is absolute, so a wrong axis sign sends it the
    // other way: it settles on the mirror of its target.
    let trace = run(&one_goto(
        goto("g1", Axis::Azimuth, 0.03),
        SimFaults {
            reverse: true,
            ..SimFaults::default()
        },
    ));
    assert_stopped_and_latched(&trace, FaultKind::MissedTarget);
    // And with room to run, it is caught on its way.
    let trace = run(&Scenario {
        config: long_gotos(),
        ..one_goto(
            goto("g1", Axis::Azimuth, 0.5),
            SimFaults {
                reverse: true,
                ..SimFaults::default()
            },
        )
    });
    assert_eq!(trace.final_state, Some(MountState::FaultLatched));
    assert!(
        matches!(trace.faults[0].kind, FaultKind::OppositeMotion),
        "{:?}",
        trace.faults
    );
    assert!(trace.travel_after(0)[0] > -0.2);
}

#[test]
fn a_goto_that_settles_off_target_latches() {
    let trace = run(&one_goto(
        goto("g1", Axis::Azimuth, 0.04),
        SimFaults {
            goto_short_deg: 0.02,
            ..SimFaults::default()
        },
    ));
    assert_stopped_and_latched(&trace, FaultKind::MissedTarget);
    let g = trace.records[0].goto.as_ref().unwrap();
    let error = units_to_deg(g.error_units.unwrap());
    assert!((error + 0.02).abs() < 1e-4, "{error}");
}

#[test]
fn an_operator_stop_ends_a_goto_short_of_its_target() {
    let mut scenario = one_goto(goto("g1", Axis::Azimuth, 0.05), SimFaults::default());
    scenario.script.push((700, Op::Stop));
    let trace = run(&scenario);
    assert!(trace.faults.is_empty(), "{:?}", trace.faults);
    assert_eq!(trace.final_state, Some(MountState::Armed));
    let record = &trace.records[0];
    assert_eq!(record.last_stage(), Stage::Cancelled);
    let g = record.goto.as_ref().unwrap();
    let (at_stop, last) = (g.at_stop.unwrap(), g.last.unwrap());
    // About 0.02° in 200 ms; it stopped within a few hundredths of a second.
    let travel = trace.travel_after(0)[0];
    assert!(travel > 0.01 && travel < 0.035, "{travel}");
    assert!(units_to_deg(units_between(at_stop, last)) < 0.01);
    // Commanded travel is where the positions showed it ended.
    assert!((record.commanded_deg.unwrap() - units_to_deg(i64::from(last))).abs() < 1e-12);
    assert!(trace.is_still_at_end());
}

#[test]
fn a_goto_the_stop_cant_end_finishes_on_its_own_and_the_record_shows_it() {
    // Within the cap (about 1 s of slow travel) a goto that ignores the stop
    // ends by itself before the stop deadline. The record shows it carried
    // on: the stop-during-goto trial looks for exactly this.
    let mut scenario = one_goto(
        goto("g1", Axis::Azimuth, 0.05),
        SimFaults {
            stop_ignores_goto: true,
            ..SimFaults::default()
        },
    );
    scenario.script.push((700, Op::Stop));
    let trace = run(&scenario);
    assert!(trace.faults.is_empty(), "{:?}", trace.faults);
    let g = trace.records[0].goto.as_ref().unwrap();
    let carried_on = units_to_deg(units_between(g.at_stop.unwrap(), g.last.unwrap()));
    assert!(carried_on > 0.02, "{carried_on}");
    assert_eq!(g.last, Some(g.target));
}

#[test]
fn a_long_goto_the_stop_cant_end_latches_and_asks_for_power_off() {
    let mut scenario = Scenario {
        config: long_gotos(),
        run_ms: 15_000,
        ..one_goto(
            goto("g1", Axis::Azimuth, 1.0),
            SimFaults {
                stop_ignores_goto: true,
                ..SimFaults::default()
            },
        )
    };
    scenario.script.push((1_500, Op::Stop));
    let trace = run(&scenario);
    assert_stopped_and_latched(&trace, FaultKind::StopNotObserved);
    assert!(
        trace
            .alerts
            .iter()
            .any(|(_, a)| a.contains("cut mount power"))
    );
    // Nothing the software sends ends it; it stops at its target.
    assert!((trace.travel_after(0)[0] - 1.0).abs() < 1e-4);
}

#[test]
fn the_approach_flag_adds_a_slow_leg_from_beyond_the_target() {
    let mut request = goto("g1", Axis::Azimuth, 0.03);
    // Arrive moving negative: first past the target, then back.
    request.approach = Some(Direction::Negative);
    request.speed = GotoSpeed::Fast;
    let trace = run(&Scenario {
        config: SafetyConfig {
            allow_fast_goto: true,
            ..long_gotos()
        },
        run_ms: 8_000,
        ..one_goto(request, SimFaults::default())
    });
    assert!(trace.faults.is_empty(), "{:?}", trace.faults);
    assert_eq!(trace.final_state, Some(MountState::Armed));
    let target = deg_to_units(0.03);
    let beyond = deg_to_units(0.03) + deg_to_units(0.15);
    let legs: Vec<(u32, GotoSpeed)> = trace
        .gotos_sent()
        .iter()
        .map(|c| match *c {
            MountCommand::Goto { target, speed, .. } => (target, speed),
            _ => unreachable!(),
        })
        .collect();
    assert_eq!(
        legs,
        [
            (beyond as u32, GotoSpeed::Fast),
            (target as u32, GotoSpeed::Slow)
        ]
    );
    // The second leg was sent while moving, with the same command.
    let ids: Vec<_> = trace
        .gotos_sent()
        .iter()
        .map(|c| match c {
            MountCommand::Goto { id, .. } => *id,
            _ => unreachable!(),
        })
        .collect();
    assert_eq!(ids[0], ids[1]);
    assert_eq!(
        stages(&trace, 0),
        [
            Stage::Requested,
            Stage::Transmitted,
            Stage::Acknowledged,
            Stage::Transmitted,
            Stage::Acknowledged,
            Stage::StopSent,
            Stage::Completed
        ]
    );
    let record = &trace.records[0];
    let g = record.goto.as_ref().unwrap();
    assert_eq!(g.legs.len(), 2);
    assert_eq!(g.error_units, Some(0));
    // The last leg came down onto the target without passing it.
    assert_eq!((g.overshoot_units, g.crossings), (0, 0));
    assert!((record.commanded_deg.unwrap() - 0.03).abs() < 1e-4);
    assert!((trace.travel_after(0)[0] - 0.03).abs() < 1e-4);

    // Already heading the approach way: one leg.
    let mut request = goto("g2", Axis::Azimuth, 0.03);
    request.approach = Some(Direction::Positive);
    let trace = run(&Scenario {
        config: long_gotos(),
        ..one_goto(request, SimFaults::default())
    });
    assert!(trace.faults.is_empty(), "{:?}", trace.faults);
    assert_eq!(trace.gotos_sent().len(), 1);
}

#[test]
fn gotos_outside_the_rules_are_refused_and_recorded() {
    let refused = |config: SafetyConfig, start_altitude_deg: f64, request: GotoRequest| {
        let trace = run(&Scenario {
            config,
            start_altitude_deg,
            ..one_goto(request, SimFaults::default())
        });
        assert!(trace.gotos_sent().is_empty());
        assert_eq!(trace.records[0].last_stage(), Stage::Rejected);
        assert_eq!(trace.final_state, Some(MountState::Armed));
        trace.refusals[0].1.clone()
    };
    let default = SafetyConfig::default;
    let why = refused(default(), 30.0, goto("g", Axis::Azimuth, 0.06));
    assert!(why.contains("max_goto_deg"), "{why}");
    // Exactly the cap is allowed, though it rounds to a unit just over it.
    let trace = run(&Scenario {
        config: SafetyConfig {
            max_goto_deg: 0.2,
            ..default()
        },
        ..one_goto(goto("g", Axis::Azimuth, 0.2), SimFaults::default())
    });
    assert_eq!(trace.gotos_sent().len(), 1, "{:?}", trace.refusals);
    let mut fast = goto("g", Axis::Azimuth, 0.03);
    fast.speed = GotoSpeed::Fast;
    let why = refused(default(), 30.0, fast);
    assert!(why.contains("fast gotos are off"), "{why}");
    let why = refused(default(), 30.0, goto("g", Axis::Azimuth, 0.00001));
    assert!(why.contains("less than one position unit"), "{why}");
    let why = refused(default(), 30.0, goto("g", Axis::Azimuth, f64::NAN));
    assert!(why.contains("less than one position unit"), "{why}");
    // The approach leg counts against the cap too.
    let mut approach = goto("g", Axis::Azimuth, 0.03);
    approach.approach = Some(Direction::Negative);
    let why = refused(default(), 30.0, approach);
    assert!(why.contains("0.1800°"), "{why}");
    // An altitude target outside the envelope, near its top.
    let why = refused(default(), 84.98, goto("g", Axis::Altitude, 0.04));
    assert!(why.contains("envelope"), "{why}");
    // Including an approach leg that would leave it.
    let mut approach = goto("g", Axis::Altitude, -0.03);
    approach.approach = Some(Direction::Positive);
    let why = refused(long_gotos(), 5.1, approach);
    assert!(why.contains("envelope"), "{why}");

    // Not armed, and a repeated ID.
    let trace = run(&Scenario {
        script: vec![
            (100, Op::Connect),
            (200, Op::Goto(goto("g", Axis::Azimuth, 0.03))),
            (300, Op::Arm),
            (500, Op::Goto(goto("g", Axis::Azimuth, 0.03))),
        ],
        ..Scenario::default()
    });
    assert!(trace.gotos_sent().is_empty());
    assert!(trace.refusals[0].1.contains("not armed"));
    assert!(trace.refusals[1].1.contains("duplicate"));
}

#[test]
fn a_goto_and_a_move_take_turns() {
    // While a goto runs, nothing else may start; afterwards, a move may.
    let scenario = Scenario {
        script: vec![
            (100, Op::Connect),
            (300, Op::Arm),
            (500, Op::Goto(goto("g1", Axis::Azimuth, 0.03))),
            (600, Op::Goto(goto("g2", Axis::Altitude, 0.03))),
            (3_000, Op::Goto(goto("g3", Axis::Azimuth, -0.03))),
        ],
        ..Scenario::default()
    };
    let trace = run(&scenario);
    assert!(trace.faults.is_empty(), "{:?}", trace.faults);
    assert!(
        trace.refusals[0].1.contains("not armed (state Moving)"),
        "{:?}",
        trace.refusals
    );
    assert_eq!(trace.records[2].last_stage(), Stage::Completed);
    // Back where it started, to the unit.
    let g = trace.records[2].goto.as_ref().unwrap();
    assert_eq!(g.last, Some(0));
    assert!(trace.travel_after(0)[0].abs() < 1e-9);
}
