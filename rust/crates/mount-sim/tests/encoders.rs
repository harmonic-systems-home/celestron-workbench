//! Encoder-only sessions (ADR 0019): the motors' positions are the feedback,
//! no phone. Gotos complete; moves are refused; arming needs the altitude
//! reference; and overshoot, a stall, idle motion and a silent link latch
//! faults as they do with the IMU.

use cwb_mount_core::{
    Axis, Direction, FaultKind, GotoRequest, GotoSpeed, MountState, MoveRequest, SafetyConfig,
    Stage,
};
use cwb_mount_sim::{
    SimFaults,
    harness::{Feedback, Op, Scenario, Trace, run},
};

fn goto(id: &str, axis: Axis, delta_deg: f64) -> GotoRequest {
    GotoRequest {
        request_id: id.into(),
        axis,
        delta_deg,
        speed: GotoSpeed::Slow,
        approach: None,
    }
}

fn config() -> SafetyConfig {
    SafetyConfig {
        encoders_only: true,
        max_goto_deg: 1.0,
        ..SafetyConfig::default()
    }
}

/// Connect at 100 ms, arm at 1 s (after a few idle reads), the goto at 1.5 s.
fn one_goto(request: GotoRequest, faults: SimFaults, run_ms: u64) -> Scenario {
    Scenario {
        config: config(),
        faults,
        script: vec![
            (100, Op::Connect),
            (1_000, Op::Arm),
            (1_500, Op::Goto(request)),
        ],
        run_ms,
        feedback: Feedback::encoders(),
        ..Scenario::default()
    }
}

fn only_fault(trace: &Trace) -> FaultKind {
    assert!(!trace.faults.is_empty(), "no fault: {:#?}", trace.records);
    trace.faults[0].kind
}

#[test]
fn a_goto_completes_with_encoder_feedback() {
    let trace = run(&one_goto(
        goto("g", Axis::Azimuth, 0.15),
        SimFaults::default(),
        6_000,
    ));
    assert!(trace.faults.is_empty(), "{:#?}", trace.faults);
    assert_eq!(trace.refusals, []);
    let stages: Vec<Stage> = trace.records[0].stages.iter().map(|s| s.0).collect();
    assert_eq!(stages.last(), Some(&Stage::Completed), "{stages:?}");
    assert_eq!(trace.final_state, Some(MountState::Armed));
    let travel = trace.travel_after(0);
    assert!((travel[0] - 0.15).abs() < 0.001, "{travel:?}");
}

#[test]
fn moves_are_refused() {
    let mut scenario = one_goto(goto("g", Axis::Azimuth, 0.15), SimFaults::default(), 3_000);
    scenario.script[2].1 = Op::Move(MoveRequest {
        request_id: "m".into(),
        axis: Axis::Azimuth,
        direction: Direction::Positive,
        rate_deg_s: 0.1,
        duration_ms: 500,
        fixed_rate: None,
    });
    let trace = run(&scenario);
    assert_eq!(trace.moves_sent(), 0);
    assert!(
        trace.refusals[0].1.contains("gotos only"),
        "{:?}",
        trace.refusals
    );
}

#[test]
fn arming_needs_the_altitude_reference() {
    let mut scenario = one_goto(goto("g", Axis::Azimuth, 0.15), SimFaults::default(), 2_000);
    scenario.feedback = Feedback::Encoders {
        read_every_ms: 250,
        reads_stop_at_ms: None,
        altitude_reference: false,
    };
    let trace = run(&scenario);
    assert!(
        trace.refusals[0]
            .1
            .contains("altitude is outside the envelope"),
        "{:?}",
        trace.refusals
    );
    assert!(trace.gotos_sent().is_empty());
}

#[test]
fn an_overshoot_beyond_the_margin_latches() {
    let faults = SimFaults {
        goto_overshoot_deg: 0.3,
        ..SimFaults::default()
    };
    let trace = run(&one_goto(goto("g", Axis::Azimuth, 0.2), faults, 8_000));
    assert_eq!(only_fault(&trace), FaultKind::Overshoot);
}

#[test]
fn a_stalled_goto_times_out() {
    let faults = SimFaults {
        stall: true,
        ..SimFaults::default()
    };
    // Deadline: 0.15° at 0.05 °/s plus 2 s.
    let trace = run(&one_goto(goto("g", Axis::Azimuth, 0.15), faults, 9_000));
    assert_eq!(only_fault(&trace), FaultKind::CommandTimeout);
    assert!(trace.is_still_at_end());
}

#[test]
fn motion_while_idle_latches() {
    let faults = SimFaults {
        bump: Some((Axis::Altitude, 0.3, 2_000, 2_600)),
        ..SimFaults::default()
    };
    let mut scenario = one_goto(goto("g", Axis::Azimuth, 0.15), faults, 4_000);
    scenario.script.truncate(2); // armed and idle
    let trace = run(&scenario);
    assert_eq!(only_fault(&trace), FaultKind::UnexpectedMotion);
    let at = trace.faults[0].t_ns as f64 / 1e6;
    assert!(at < 2_700.0, "caught at {at} ms");
}

#[test]
fn the_other_axis_moving_during_a_goto_is_caught_once_it_is_read() {
    // Altitude isn't read while an azimuth goto is watched; a push then shows
    // up in the first idle reads after the goto.
    let faults = SimFaults {
        bump: Some((Axis::Altitude, 0.3, 1_550, 4_000)),
        ..SimFaults::default()
    };
    let trace = run(&one_goto(goto("g", Axis::Azimuth, 0.15), faults, 6_000));
    assert_eq!(only_fault(&trace), FaultKind::UnexpectedMotion);
}

#[test]
fn silent_position_reads_latch_while_armed() {
    let mut scenario = one_goto(goto("g", Axis::Azimuth, 0.15), SimFaults::default(), 4_000);
    scenario.script.truncate(2);
    scenario.feedback = Feedback::Encoders {
        read_every_ms: 250,
        reads_stop_at_ms: Some(2_000),
        altitude_reference: true,
    };
    let trace = run(&scenario);
    assert_eq!(only_fault(&trace), FaultKind::StaleImu);
}

#[test]
fn a_two_leg_approach_goto_completes() {
    // Heading negative but asked to finish moving positive: past the target
    // by the margin, then back.
    let mut request = goto("g", Axis::Azimuth, -0.1);
    request.approach = Some(Direction::Positive);
    let trace = run(&one_goto(request, SimFaults::default(), 12_000));
    assert!(trace.faults.is_empty(), "{:#?}", trace.faults);
    assert_eq!(trace.gotos_sent().len(), 2);
    let stages: Vec<Stage> = trace.records[0].stages.iter().map(|s| s.0).collect();
    assert_eq!(stages.last(), Some(&Stage::Completed), "{stages:?}");
    let travel = trace.travel_after(0);
    assert!((travel[0] + 0.1).abs() < 0.001, "{travel:?}");
}
