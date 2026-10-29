//! The Celestron adapter against the simulated hand controller and mount:
//! the bytes it may send, acknowledgements, stops, link loss, and stopping
//! when it is dropped. These run in real time (the adapter has a thread).

use std::{
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

use cwb_mount_celestron::{
    CelestronAdapter, CelestronSettings, StopForm,
    adapter::Clock,
    encode::{quantized_deg_s, rate_units, transactions},
    fake::SimHandController,
    prepare::prepare,
};
use cwb_mount_core::{Axis, Direction, MountAdapter, MountCommand, MountReport};
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

#[test]
fn moves_and_stops_are_the_documented_pass_through_bytes() {
    // 0.1 °/s = 360″/s, × 4 = 1440 = 0x05A0.
    assert_eq!(
        transactions(
            &mv(Axis::Azimuth, Direction::Positive, 0.1),
            CelestronSettings::default()
        ),
        [[b'P', 3, 16, 6, 0x05, 0xA0, 0, 0]]
    );
    assert_eq!(
        transactions(
            &mv(Axis::Altitude, Direction::Negative, 0.1),
            CelestronSettings::default()
        ),
        [[b'P', 3, 17, 7, 0x05, 0xA0, 0, 0]]
    );
    let reversed = CelestronSettings {
        reverse_azimuth: true,
        ..CelestronSettings::default()
    };
    assert_eq!(
        transactions(&mv(Axis::Azimuth, Direction::Positive, 0.1), reversed)[0][3],
        7
    );
    assert_eq!(
        transactions(
            &MountCommand::Stop {
                axis: Axis::Altitude
            },
            reversed
        ),
        [[b'P', 3, 17, 6, 0, 0, 0, 0], [b'P', 2, 17, 36, 0, 0, 0, 0]]
    );
    assert_eq!(
        transactions(&MountCommand::StopAll, reversed).len(),
        4,
        "both axes, both stop forms"
    );
    // The stop-form trial: a move's own stop can be one form; StopAll is both.
    for (form, expected) in [
        (StopForm::Variable, vec![[b'P', 3, 16, 6, 0, 0, 0, 0]]),
        (StopForm::Fixed, vec![[b'P', 2, 16, 36, 0, 0, 0, 0]]),
    ] {
        let settings = CelestronSettings {
            stop: form,
            ..CelestronSettings::default()
        };
        assert_eq!(
            transactions(
                &MountCommand::Stop {
                    axis: Axis::Azimuth
                },
                settings
            ),
            expected
        );
        assert_eq!(transactions(&MountCommand::StopAll, settings).len(), 4);
    }
    assert_eq!(rate_units(1e-9), 1, "a move is never rate 0");
    assert!((quantized_deg_s(0.001) - 14.0 / 4.0 / 3600.0).abs() < 1e-12);
}

#[test]
fn every_transaction_is_a_variable_rate_slew_or_a_stop() {
    let mut all = Vec::new();
    for axis in Axis::BOTH {
        for direction in [Direction::Positive, Direction::Negative] {
            for rate in [0.001, 0.1, 1.0, 4.5] {
                all.extend(transactions(
                    &mv(axis, direction, rate),
                    CelestronSettings::default(),
                ));
            }
        }
        all.extend(transactions(
            &MountCommand::Stop { axis },
            CelestronSettings::default(),
        ));
    }
    all.extend(transactions(
        &MountCommand::StopAll,
        CelestronSettings::default(),
    ));
    for t in all {
        let slew = t[1] == 3 && [6, 7].contains(&t[3]) && t[6..] == [0, 0];
        let fixed_stop = t[1] == 2 && t[3] == 36 && t[4..] == [0, 0, 0, 0];
        assert!(
            t[0] == b'P' && [16, 17].contains(&t[2]) && (slew || fixed_stop),
            "{t:?}"
        );
    }
}

#[test]
fn a_move_is_acknowledged_runs_and_stops() {
    let mut rig = rig(SimFaults::default());
    rig.adapter
        .send(&mv(Axis::Azimuth, Direction::Positive, 0.5), 0)
        .unwrap();
    let reports = rig.run(150);
    assert_eq!(reports, [MountReport::Acknowledged(7)]);
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
    let last: Vec<Vec<u8>> = received
        .lock()
        .unwrap()
        .iter()
        .rev()
        .take(4)
        .cloned()
        .collect();
    assert!(
        last.iter().all(|c| c[0] == b'P' && c[4..] == [0, 0, 0, 0]),
        "{last:?}"
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
    assert_eq!(reports, [MountReport::TransportLost]);
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
        before + 4,
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
