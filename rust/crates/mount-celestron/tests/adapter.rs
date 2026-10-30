//! The Celestron adapter against the simulated hand controller and mount:
//! the bytes it may send, acknowledgements, stops, link loss, and stopping
//! when it is dropped. These run in real time (the adapter has a thread).

use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use cwb_mount_celestron::{
    CelestronAdapter, CelestronSettings,
    adapter::Clock,
    encode::{quantized_deg_s, rate_units, transactions},
    fake::SimHandController,
    prepare::prepare,
};
use cwb_mount_core::{
    Axis, Direction, GotoSpeed, MountAdapter, MountCommand, MountReport, deg_to_units,
};
use cwb_mount_sim::{SimFaults, SimMount};

fn clock() -> Clock {
    let start = Instant::now();
    Arc::new(move || start.elapsed().as_nanos() as i64)
}

fn mv(axis: Axis, direction: Direction, rate_deg_s: f64) -> MountCommand {
    MountCommand::Move {
        id: 7,
        axis,
        direction,
        rate_deg_s,
    }
}

struct Rig {
    mount: Arc<Mutex<SimMount>>,
    adapter: CelestronAdapter,
    received: Arc<Mutex<Vec<Vec<u8>>>>,
    clock: Clock,
    last_step: i64,
}

fn rig(faults: SimFaults) -> Rig {
    rig_with(faults, None)
}

fn rig_with(faults: SimFaults, position_every: Option<Duration>) -> Rig {
    let clock = clock();
    let mount = Arc::new(Mutex::new(SimMount::new(faults, 30.0, 1)));
    let hc = SimHandController::new(mount.clone(), clock.clone());
    let received = hc.received.clone();
    let adapter = CelestronAdapter::spawn(
        hc,
        CelestronSettings::default(),
        clock.clone(),
        position_every,
    );
    Rig {
        mount,
        adapter,
        received,
        last_step: clock(),
        clock,
    }
}

impl Rig {
    /// Runs the simulated physics in real time for `ms`, collecting reports.
    fn run(&mut self, ms: u64) -> Vec<MountReport> {
        let end = Instant::now() + Duration::from_millis(ms);
        let mut reports = Vec::new();
        while Instant::now() < end {
            std::thread::sleep(Duration::from_millis(2));
            let now = (self.clock)();
            self.mount.lock().unwrap().step(now, now - self.last_step);
            self.last_step = now;
            reports.extend(self.adapter.poll(now));
        }
        reports
    }

    fn rates(&self) -> [f64; 2] {
        self.mount.lock().unwrap().rates_deg_s()
    }

    fn angles(&self) -> [f64; 2] {
        self.mount.lock().unwrap().angles_deg()
    }
}

fn bytes(command: &MountCommand, settings: CelestronSettings) -> Vec<Vec<u8>> {
    transactions(command, settings)
        .into_iter()
        .map(|t| t.bytes)
        .collect()
}

#[test]
fn moves_and_stops_are_the_documented_bytes() {
    // 0.1 °/s = 360″/s, × 4 = 1440 = 0x05A0.
    assert_eq!(
        bytes(
            &mv(Axis::Azimuth, Direction::Positive, 0.1),
            CelestronSettings::default()
        ),
        [vec![b'P', 3, 16, 6, 0x05, 0xA0, 0, 0]]
    );
    assert_eq!(
        bytes(
            &mv(Axis::Altitude, Direction::Negative, 0.1),
            CelestronSettings::default()
        ),
        [vec![b'P', 3, 17, 7, 0x05, 0xA0, 0, 0]]
    );
    let reversed = CelestronSettings {
        reverse_azimuth: true,
        ..CelestronSettings::default()
    };
    assert_eq!(
        bytes(&mv(Axis::Azimuth, Direction::Positive, 0.1), reversed)[0][3],
        7
    );
    // A stop: tracking off (to the hand controller), then fixed rate 0.
    let stop = transactions(
        &MountCommand::Stop {
            axis: Axis::Altitude,
        },
        reversed,
    );
    assert_eq!(stop[0].bytes, [b'T', 0]);
    assert!(!stop[0].pass_through);
    assert_eq!(stop[1].bytes, [b'P', 2, 17, 36, 0, 0, 0, 0]);
    assert!(stop[1].pass_through);
    assert_eq!(
        bytes(&MountCommand::StopAll, reversed),
        [
            vec![b'T', 0],
            vec![b'P', 2, 16, 36, 0, 0, 0, 0],
            vec![b'P', 2, 17, 36, 0, 0, 0, 0]
        ]
    );
    assert_eq!(rate_units(1e-9), 1, "a move is never rate 0");
    assert!((quantized_deg_s(0.001) - 14.0 / 4.0 / 3600.0).abs() < 1e-12);
}

#[test]
fn variable_rate_0_is_never_sent() {
    let mut all = Vec::new();
    for axis in Axis::BOTH {
        for direction in [Direction::Positive, Direction::Negative] {
            for rate in [0.0, 1e-9, 0.001, 0.1, 1.0, 4.5] {
                all.extend(bytes(
                    &mv(axis, direction, rate),
                    CelestronSettings::default(),
                ));
            }
        }
        all.extend(bytes(
            &MountCommand::Stop { axis },
            CelestronSettings::default(),
        ));
    }
    all.extend(bytes(&MountCommand::StopAll, CelestronSettings::default()));
    for t in all {
        let tracking_off = t == [b'T', 0];
        let slew = t.len() == 8
            && t[0] == b'P'
            && t[1] == 3
            && [6, 7].contains(&t[3])
            && t[4..6] != [0, 0]
            && t[6..] == [0, 0];
        let fixed_zero =
            t.len() == 8 && t[0] == b'P' && t[1] == 2 && t[3] == 36 && t[4..] == [0, 0, 0, 0];
        assert!(
            tracking_off || ((slew || fixed_zero) && [16, 17].contains(&t[2])),
            "{t:?}"
        );
    }
}

fn goto(axis: Axis, target: u32, speed: GotoSpeed) -> MountCommand {
    MountCommand::Goto {
        id: 9,
        axis,
        target,
        speed,
    }
}

#[test]
fn gotos_are_the_documented_bytes_and_nothing_else() {
    assert_eq!(
        bytes(
            &goto(Axis::Azimuth, 0x12_3456, GotoSpeed::Slow),
            CelestronSettings::default()
        ),
        [vec![b'P', 4, 16, 0x17, 0x12, 0x34, 0x56, 0]]
    );
    assert_eq!(
        bytes(
            &goto(Axis::Altitude, 300, GotoSpeed::Fast),
            CelestronSettings::default()
        ),
        [vec![b'P', 4, 17, 0x02, 0, 0x01, 0x2C, 0]]
    );
    // A reversed axis counts the other way: one unit up is one unit below 0.
    let reversed = CelestronSettings {
        reverse_altitude: true,
        ..CelestronSettings::default()
    };
    assert_eq!(
        bytes(&goto(Axis::Altitude, 1, GotoSpeed::Slow), reversed),
        [vec![b'P', 4, 17, 0x17, 0xFF, 0xFF, 0xFF, 0]]
    );
    assert_eq!(reversed.flip_units(Axis::Altitude, 0xFF_FFFF), 1);
    assert_eq!(reversed.flip_units(Axis::Azimuth, 5), 5);
    for axis in Axis::BOTH {
        for speed in [GotoSpeed::Slow, GotoSpeed::Fast] {
            for target in [0, 1, 0x80_0000, 0xFF_FFFF] {
                for settings in [CelestronSettings::default(), reversed] {
                    let all = bytes(&goto(axis, target, speed), settings);
                    assert_eq!(all.len(), 1);
                    let t = &all[0];
                    assert_eq!(t.len(), 8);
                    assert_eq!(t[..2], [b'P', 4], "{t:?}");
                    assert!([16, 17].contains(&t[2]), "{t:?}");
                    assert!([0x02, 0x17].contains(&t[3]), "{t:?}");
                    assert_eq!(t[7], 0, "{t:?}");
                }
            }
        }
    }
}

#[test]
fn a_goto_is_watched_until_it_settles() {
    let mut rig = rig_with(SimFaults::default(), Some(Duration::from_millis(250)));
    let target = deg_to_units(0.02) as u32;
    rig.adapter
        .send(&goto(Axis::Azimuth, target, GotoSpeed::Slow), 0)
        .unwrap();
    let reports = rig.run(1_000);
    assert!(
        matches!(
            reports[..2],
            [
                MountReport::Sent { id: 9, .. },
                MountReport::Acknowledged(9)
            ]
        ),
        "{reports:?}"
    );
    let watch = &reports[2..];
    assert!(watch.len() >= 6, "{watch:?}");
    // Position and flag in turn, ending on a repeated position after done.
    for (i, r) in watch.iter().enumerate() {
        let position = matches!(
            r,
            MountReport::Position {
                axis: Axis::Azimuth,
                ..
            }
        );
        assert_eq!(position, i % 2 == 0, "{watch:?}");
    }
    assert!(
        watch.contains(&MountReport::SlewDone {
            axis: Axis::Azimuth,
            t_ns: match watch
                .iter()
                .find(|r| matches!(r, MountReport::SlewDone { done: true, .. }))
            {
                Some(MountReport::SlewDone { t_ns, .. }) => *t_ns,
                _ => panic!("never done: {watch:?}"),
            },
            done: true
        })
    );
    let positions: Vec<u32> = watch
        .iter()
        .filter_map(|r| match r {
            MountReport::Position { units, .. } => Some(*units),
            _ => None,
        })
        .collect();
    let n = positions.len();
    assert_eq!(positions[n - 2..], [target, target], "{positions:?}");
    assert_eq!(rig.angles()[1], 0.0);
    // The watch read only the motor controller.
    let sent = rig.received.lock().unwrap().clone();
    let goto_at = sent.iter().position(|c| c[0] == b'P' && c[1] == 4).unwrap();
    let after = &sent[goto_at + 1..];
    let reads = after.iter().take_while(|c| c[0] == b'P').count();
    assert!(reads >= 6, "{sent:?}");
    for c in &after[..reads] {
        assert!(
            *c == [b'P', 1, 16, 0x01, 0, 0, 0, 3] || *c == [b'P', 1, 16, 0x13, 0, 0, 0, 1],
            "{c:?}"
        );
    }
    // Nothing else: `z` reads wait for the controller's stop, which ends
    // every goto.
    assert_eq!(reads, after.len(), "{:?}", &after[reads..]);
}

#[test]
fn the_watch_outlasts_a_stop_during_a_goto() {
    let mut rig = rig(SimFaults::default());
    rig.adapter
        .send(
            &goto(Axis::Azimuth, deg_to_units(0.05) as u32, GotoSpeed::Slow),
            0,
        )
        .unwrap();
    rig.run(200);
    rig.adapter
        .send(
            &MountCommand::Stop {
                axis: Axis::Azimuth,
            },
            0,
        )
        .unwrap();
    let reports = rig.run(600);
    assert_eq!(rig.rates(), [0.0, 0.0]);
    // The simulated motors, like the mount's, ignore tracking off and fixed
    // rate 0 during a goto: the re-aimed goto is what stopped it short.
    let travel = rig.angles()[0];
    assert!((0.01..0.035).contains(&travel), "{travel}");
    // The re-aim goes before the usual stop.
    let sent = rig.received.lock().unwrap().clone();
    let commands: Vec<&Vec<u8>> = sent
        .iter()
        .filter(|c| c[0] == b'T' || (c[0] == b'P' && [2, 4].contains(&c[1])))
        .collect();
    assert_eq!(commands[0][..4], [b'P', 4, 16, 0x17], "{commands:?}");
    assert_eq!(commands[1][..4], [b'P', 4, 16, 0x17], "{commands:?}");
    assert_eq!(commands[2], &b"T\0".to_vec());
    assert_eq!(commands[3], &vec![b'P', 2, 16, 36, 0, 0, 0, 0]);
    assert!(
        reports
            .iter()
            .any(|r| matches!(r, MountReport::SlewDone { done: true, .. })),
        "{reports:?}"
    );
    let last = reports
        .iter()
        .rev()
        .find_map(|r| match r {
            MountReport::Position { units, .. } => Some(*units),
            _ => None,
        })
        .unwrap();
    assert_eq!(last, deg_to_units(travel) as u32);
}

#[test]
fn a_move_is_acknowledged_runs_and_stops() {
    let mut rig = rig(SimFaults::default());
    rig.adapter
        .send(&mv(Axis::Azimuth, Direction::Positive, 0.5), 0)
        .unwrap();
    let reports = rig.run(150);
    assert!(
        matches!(
            reports[..],
            [MountReport::Sent { id: 7, sent_ns }, MountReport::Acknowledged(7)]
                if sent_ns < 150_000_000
        ),
        "{reports:?}"
    );
    rig.run(400);
    assert!((rig.rates()[0] - 0.5).abs() < 1e-6, "{:?}", rig.rates());
    rig.adapter
        .send(
            &MountCommand::Stop {
                axis: Axis::Azimuth,
            },
            0,
        )
        .unwrap();
    rig.run(300);
    assert_eq!(rig.rates(), [0.0, 0.0]);
    let travel = rig.angles()[0];
    assert!((0.15..0.35).contains(&travel), "{travel}");
    assert_eq!(rig.angles()[1], 0.0, "the other axis never moved");
}

#[test]
fn dropping_the_adapter_stops_both_axes() {
    let mut rig = rig(SimFaults::default());
    rig.adapter
        .send(&mv(Axis::Altitude, Direction::Negative, 0.3), 0)
        .unwrap();
    rig.run(200);
    assert!(rig.rates()[1] < -0.1);
    let Rig {
        mount,
        adapter,
        received,
        ..
    } = rig;
    drop(adapter);
    let received = received.lock().unwrap();
    let last = &received[received.len() - 3..];
    assert_eq!(
        last,
        [
            vec![b'T', 0],
            vec![b'P', 2, 16, 36, 0, 0, 0, 0],
            vec![b'P', 2, 17, 36, 0, 0, 0, 0]
        ]
    );
    let mut m = mount.lock().unwrap();
    m.step(10_000_000_000, 1_000_000_000);
    assert_eq!(m.rates_deg_s(), [0.0, 0.0]);
}

#[test]
fn a_dropped_link_is_reported_once_and_stops_are_still_attempted() {
    let mut rig = rig(SimFaults {
        disconnect_at_ms: Some(0),
        ..SimFaults::default()
    });
    // The simulated link only drops once the mount is polled.
    rig.mount.lock().unwrap().poll(1);
    rig.adapter
        .send(&mv(Axis::Azimuth, Direction::Positive, 0.1), 0)
        .unwrap();
    let reports = rig.run(100);
    // The move was written before the failure showed: sent, never acknowledged.
    assert!(
        matches!(
            reports[..],
            [MountReport::Sent { id: 7, .. }, MountReport::TransportLost]
        ),
        "{reports:?}"
    );
    assert!(
        rig.adapter
            .send(&mv(Axis::Azimuth, Direction::Positive, 0.1), 0)
            .is_err()
    );
    let before = rig.received.lock().unwrap().len();
    assert!(rig.adapter.send(&MountCommand::StopAll, 0).is_err());
    rig.run(100);
    assert_eq!(
        rig.received.lock().unwrap().len(),
        before + 3,
        "the stop went out anyway; the move didn't"
    );
}

#[test]
fn preparation_turns_tracking_off_and_reads_positions() {
    let clock = clock();
    let mount = Arc::new(Mutex::new(SimMount::new(SimFaults::default(), 30.0, 1)));
    let mut hc = SimHandController::new(mount, clock);
    hc.tracking = 1;
    let (hc, prepared) = prepare(hc);
    let prepared = prepared.unwrap();
    assert_eq!(hc.tracking, 0);
    assert_eq!(prepared.positions_deg, [0.0, 0.0]);
    assert_eq!(prepared.backlash, [[Some(0), Some(0)], [Some(0), Some(0)]]);
    assert_eq!(
        prepared.identity.model.as_deref(),
        Some("22 (NexStar Evolution)")
    );
    assert!(
        prepared.notes[0].contains("turned it off"),
        "{:?}",
        prepared.notes
    );
    let sent: Vec<u8> = hc.received.lock().unwrap().iter().map(|c| c[0]).collect();
    assert!(
        sent.iter().all(|b| b"KVmPLtTz".contains(b)),
        "queries and T only: {:?}",
        String::from_utf8_lossy(&sent)
    );
    assert!(
        hc.received
            .lock()
            .unwrap()
            .iter()
            .filter(|c| c[0] == b'P')
            .all(|c| c[1] == 1 && [254, 0x40, 0x41].contains(&c[3])),
        "pass-through gets only"
    );
}

#[test]
fn a_link_that_dies_while_idle_is_reported_without_any_command() {
    let mut rig = rig_with(SimFaults::default(), Some(Duration::from_millis(20)));
    rig.run(150);
    assert!(
        !rig.adapter.take_positions().is_empty(),
        "positions are read while idle"
    );
    // The USB link goes away (the simulated mount drops when polled).
    {
        let mut m = rig.mount.lock().unwrap();
        *m = SimMount::new(
            SimFaults {
                disconnect_at_ms: Some(0),
                ..SimFaults::default()
            },
            30.0,
            1,
        );
        m.poll(1);
    }
    let reports = rig.run(200);
    assert_eq!(
        reports,
        [MountReport::TransportLost],
        "once, with no command sent"
    );
    let notes = rig.adapter.take_notes();
    assert_eq!(notes.len(), 1, "{notes:?}");
    assert!(notes[0].contains("serial port failed"));
}

#[test]
fn positions_are_not_read_between_a_move_and_its_stop() {
    let mut rig = rig_with(SimFaults::default(), Some(Duration::from_millis(20)));
    rig.run(100);
    rig.adapter
        .send(&mv(Axis::Azimuth, Direction::Positive, 0.1), 0)
        .unwrap();
    rig.run(300);
    rig.adapter
        .send(
            &MountCommand::Stop {
                axis: Axis::Azimuth,
            },
            0,
        )
        .unwrap();
    rig.run(200);
    let sent: Vec<u8> = rig.received.lock().unwrap().iter().map(|c| c[0]).collect();
    let text = String::from_utf8_lossy(&sent).into_owned();
    let (before, after) = text.split_at(text.find('P').unwrap());
    assert!(before.contains('z'), "read while idle: {text}");
    let between = &after[..after.rfind('P').unwrap()];
    assert!(!between.contains('z'), "no reads during the move: {text}");
    assert!(
        after[after.rfind('P').unwrap()..].contains('z'),
        "reads resume: {text}"
    );
}

#[test]
fn stops_resent_faster_than_the_read_interval_do_not_starve_position_reads() {
    // A latched fault re-sends StopAll every 250 ms; reads come every 250 ms.
    let mut rig = rig_with(SimFaults::default(), Some(Duration::from_millis(250)));
    rig.run(300);
    rig.adapter.take_positions();
    for _ in 0..15 {
        rig.adapter.send(&MountCommand::StopAll, 0).unwrap();
        rig.run(100);
    }
    let reads = rig.adapter.take_positions().len();
    assert!((5..=8).contains(&reads), "{reads} reads in 1.5 s");
}

#[test]
fn the_stop_test_can_only_send_rate_zero_commands() {
    use cwb_mount_celestron::stoptest::StopForm;
    for axis in Axis::BOTH {
        for form in StopForm::ALL {
            let b = form.bytes(axis);
            assert_eq!(b[0], b'P');
            assert!([16, 17].contains(&b[2]));
            assert!(
                (b[1] == 3 && [6, 7].contains(&b[3])) || (b[1] == 2 && [36, 37].contains(&b[3])),
                "{b:?}"
            );
            assert_eq!(b[4..], [0, 0, 0, 0], "{form}: rate 0, nothing else");
            assert_eq!(StopForm::parse(&form.to_string()), Some(form));
        }
    }
}

#[test]
fn the_stop_test_measures_rates_from_positions() {
    use cwb_mount_celestron::stoptest::{Reading, rate_arcsec_s};
    let r = |s: f64, a: f64, b: f64| Reading {
        t_ns: (s * 1e9) as i64,
        deg: [a, b],
    };
    // 0.21″/s on azimuth across 0°; altitude still.
    let rates = rate_arcsec_s(&[
        r(0.0, 359.9999, 26.0),
        r(10.0, 359.9999 + 2.1 / 3600.0 - 360.0, 26.0),
    ])
    .unwrap();
    assert!((rates[0] - 0.21).abs() < 1e-6, "{rates:?}");
    assert_eq!(rates[1], 0.0);
    assert!(rate_arcsec_s(&[r(0.0, 0.0, 0.0)]).is_none());
}

#[test]
fn cancel_candidates_are_stops_or_state_commands_and_one_tiny_nudge() {
    use cwb_mount_celestron::stoptest::Cancel;
    for axis in Axis::BOTH {
        for c in Cancel::ALL {
            for s in c.steps(axis) {
                let b = &s.bytes;
                let ok = match b[0] {
                    b'T' => b == &[b'T', 0],
                    b'M' => b.len() == 1,
                    b'P' => {
                        [16, 17].contains(&b[2])
                            && b[5..8] == [0, 0, 0]
                            && match (b[1], b[3]) {
                                // Fixed rate: only 0, or 1 in the nudge.
                                (2, 36 | 37) => b[4] == 0 || (c == Cancel::FixedNudge && b[4] == 1),
                                // 24-bit guide rate: only 0.
                                (4, 6 | 7) => b[4] == 0,
                                _ => false,
                            }
                    }
                    _ => false,
                };
                assert!(ok, "{c}: {b:?}");
            }
        }
    }
}

#[test]
fn the_simulated_motors_creep_on_variable_rate_0_and_only_tracking_off_cancels_it() {
    use cwb_mount_celestron::stoptest::{self, Cancel, StopForm};
    let clock = clock();
    let mount = Arc::new(Mutex::new(SimMount::new(SimFaults::default(), 30.0, 1)));
    let mut hc = SimHandController::new(mount.clone(), clock.clone());
    stoptest::send(&mut hc, &clock, Axis::Azimuth, StopForm::VariablePositive);
    let step = |m: &Arc<Mutex<SimMount>>| {
        let mut m = m.lock().unwrap();
        for i in 1..=100 {
            m.step(i * 10_000_000, 10_000_000);
        }
        m.rates_deg_s()[0] * 3600.0
    };
    assert!(
        (step(&mount) - 0.21).abs() < 1e-6,
        "creeps at the slowest rate"
    );
    for c in [Cancel::FixedZeroPositive, Cancel::FixedZeroNegative] {
        stoptest::run_cancel(&mut hc, Axis::Azimuth, c);
        assert!(step(&mount) > 0.2, "{c} doesn't cancel it");
    }
    stoptest::run_cancel(&mut hc, Axis::Azimuth, Cancel::TrackingOff);
    assert_eq!(step(&mount), 0.0, "tracking off does");
}

#[test]
fn a_real_move_ends_cleanly_with_the_adapter_stop() {
    let mut rig = rig_with(SimFaults::default(), Some(Duration::from_millis(50)));
    rig.adapter
        .send(&mv(Axis::Azimuth, Direction::Positive, 0.2), 0)
        .unwrap();
    rig.run(300);
    rig.adapter
        .send(
            &MountCommand::Stop {
                axis: Axis::Azimuth,
            },
            0,
        )
        .unwrap();
    rig.run(300);
    let after = rig.angles();
    rig.run(500);
    assert_eq!(rig.rates(), [0.0, 0.0]);
    assert_eq!(rig.angles(), after, "no creep after the stop");
}
