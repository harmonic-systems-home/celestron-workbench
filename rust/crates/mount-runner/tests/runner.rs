//! The runner core against the simulated mount, on simulated time: the
//! checklist gate, first-move confirmation, Enter as stop, quitting, the
//! live phone path (tap, clock model, axis conversion) and the run log.

use std::{
    io::Write,
    sync::{Arc, Mutex},
};

use cwb_mount_celestron::Position;
use cwb_mount_core::{
    Axis, MountAdapter, MountCommand, MountReport, MountState, Nanos, Stage, TransportError,
    units_to_deg, wrap_units,
};
use cwb_mount_runner::{Kind, Out, RunLog, Runner, RunnerAdapter, RunnerConfig};
use cwb_mount_sim::{SimFaults, SimMount};
use cwb_protocol::{
    AttitudeReferenceFrame, ClockResult, DeviceInfo, DeviceMotionSample, GyroSample, Hello,
    Message, PROTOCOL_VERSION, Quaternion, Sample, SampleBatch, SensorAvailability, Stream,
};
use cwb_receiver::Tapped;

const MS: Nanos = 1_000_000;
const MAC_BOOT: &str = "mac-run-1";
const SESSION: &str = "11111111-1111-4111-8111-111111111111";

fn config() -> RunnerConfig {
    RunnerConfig::parse(include_str!("../../../../config/mount.toml")).unwrap()
}

/// A log that tests can read back.
#[derive(Clone, Default)]
struct Shared(Arc<Mutex<Vec<u8>>>);

impl Write for Shared {
    fn write(&mut self, buf: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(buf);
        Ok(buf.len())
    }
    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Shared {
    fn events(&self) -> Vec<String> {
        String::from_utf8(self.0.lock().unwrap().clone())
            .unwrap()
            .lines()
            .map(|l| {
                let v: serde_json::Value = serde_json::from_str(l).unwrap();
                v["event"].as_str().unwrap().to_owned()
            })
            .collect()
    }
}

struct Sim {
    runner: Runner<SimMount>,
    now: Nanos,
    out: Vec<Out>,
    log: Shared,
}

impl Sim {
    fn new(hardware: bool, faults: SimFaults) -> Self {
        let log = Shared::default();
        let (runner, out) = Runner::new(
            config(),
            SimMount::new(faults, 30.0, 1),
            RunLog::new(Box::new(log.clone())),
            hardware,
            MAC_BOOT,
            0,
        )
        .unwrap();
        Self {
            runner,
            now: 0,
            out,
            log,
        }
    }

    fn line(&mut self, text: &str) {
        let out = self.runner.line(text, self.now);
        self.out.extend(out);
    }

    /// Steps physics, the simulated IMU (100 Hz) and the runner.
    fn run(&mut self, ms: u64) {
        for _ in 0..ms / 5 {
            self.now += 5 * MS;
            let mount = self.runner.adapter_mut();
            mount.step(self.now, 5 * MS);
            if self.now % (10 * MS) == 0
                && let Some(o) = mount.observation(self.now)
            {
                let out = self.runner.observation(o, self.now);
                self.out.extend(out);
            }
            let out = self.runner.tick(self.now);
            self.out.extend(out);
        }
    }

    fn said(&self, kind: Kind, needle: &str) -> bool {
        self.out
            .iter()
            .any(|o| o.kind == kind && o.text.contains(needle))
    }

    fn moves_sent(&self) -> usize {
        self.runner
            .adapter()
            .received
            .iter()
            .filter(|(_, c)| matches!(c, MountCommand::Move { .. }))
            .count()
    }

    fn gotos_sent(&self) -> Vec<MountCommand> {
        self.runner
            .adapter()
            .received
            .iter()
            .filter(|(_, c)| matches!(c, MountCommand::Goto { .. }))
            .map(|(_, c)| c.clone())
            .collect()
    }

    fn ready(hardware: bool) -> Self {
        let mut sim = Self::new(hardware, SimFaults::default());
        sim.line("yes");
        sim.run(500);
        sim.line("arm");
        assert_eq!(sim.runner.state(), MountState::Armed, "{:#?}", sim.out);
        sim
    }
}

#[test]
fn nothing_connects_or_arms_before_the_checklist() {
    let mut sim = Sim::new(true, SimFaults::default());
    assert!(sim.said(Kind::Prompt, "Type yes when every item holds"));
    sim.run(300);
    sim.line("arm");
    sim.line("az+");
    assert!(sim.said(Kind::Prompt, "Confirm the checklist first"));
    assert_eq!(sim.runner.state(), MountState::Disconnected);
    sim.line("yes");
    assert_eq!(sim.runner.state(), MountState::ConnectedReadOnly);
    assert_eq!(sim.moves_sent(), 0);
}

#[test]
fn a_move_runs_its_lease_and_reports_commanded_and_observed_travel() {
    let mut sim = Sim::ready(false);
    sim.line("az+ 0.5 1");
    sim.run(2500);
    let records = sim.runner.controller().records();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].last_stage(), Stage::Completed);
    let commanded = records[0].commanded_deg.unwrap();
    let observed = records[0].observed_deg.unwrap();
    assert!((commanded - 0.5).abs() < 0.02, "{commanded}");
    assert!((observed - commanded).abs() < 0.1, "{observed}");
    assert!(sim.said(Kind::Info, "azimuth positive: Completed, commanded +0.50"));
    assert_eq!(sim.runner.state(), MountState::Armed);
}

#[test]
fn on_hardware_the_first_move_each_way_needs_yes() {
    let mut sim = Sim::ready(true);
    sim.line("az+ 0.2 0.5");
    assert!(sim.said(Kind::Prompt, "First azimuth positive on the mount"));
    sim.run(200);
    assert_eq!(sim.moves_sent(), 0, "nothing sent before yes");
    sim.line("yes");
    assert_eq!(sim.moves_sent(), 1);
    sim.run(1500);
    sim.line("az+ 0.2 0.5");
    assert_eq!(
        sim.moves_sent(),
        2,
        "the same way again needs no confirmation"
    );
    sim.run(1500);
    sim.line("az- 0.2 0.5");
    assert_eq!(sim.moves_sent(), 2, "the other way does");
    sim.line("");
    sim.line("yes");
    assert_eq!(sim.moves_sent(), 2, "Enter cancelled the pending move");
}

#[test]
fn a_goto_runs_to_its_target_and_reports_how_it_settled() {
    let mut sim = Sim::ready(false);
    sim.line("goto az +0.03");
    assert!(sim.said(
        Kind::Info,
        "goto: slow azimuth goto +0.0300° from 0 to 1398"
    ));
    sim.run(3_000);
    let records = sim.runner.controller().records();
    assert_eq!(records.len(), 1);
    assert_eq!(records[0].last_stage(), Stage::Completed, "{:#?}", sim.out);
    assert_eq!(records[0].goto.as_ref().unwrap().error_units, Some(0));
    assert!(sim.said(
        Kind::Info,
        "slow azimuth goto +0.0300°: Completed, commanded +0.0300°"
    ));
    assert!(sim.said(Kind::Info, "off target +0 units (+0.0″), overshoot 0 units"));
    assert!(sim.said(Kind::Info, "settled"));
    assert_eq!(sim.runner.state(), MountState::Armed);
    let events = sim.log.events();
    for e in [
        "goto_request",
        "goto_start",
        "goto_position",
        "goto_done",
        "record",
    ] {
        assert!(events.iter().any(|x| x == e), "{e} not in {events:?}");
    }
}

#[test]
fn on_hardware_the_first_goto_per_axis_and_speed_needs_yes() {
    let mut sim = Sim::ready(true);
    sim.line("goto az 0.03");
    assert!(sim.said(
        Kind::Prompt,
        "First slow azimuth goto on the mount: +0.0300° (+1398 units of 0.077″)"
    ));
    sim.run(200);
    assert!(sim.gotos_sent().is_empty(), "nothing sent before yes");
    sim.line("yes");
    assert_eq!(sim.gotos_sent().len(), 1);
    sim.run(3_000);
    sim.line("goto az -0.03");
    assert_eq!(sim.gotos_sent().len(), 2, "the same axis and speed again");
    sim.run(3_000);
    sim.line("goto alt 0.03");
    assert!(sim.said(Kind::Prompt, "First slow altitude goto"));
    sim.line("");
    sim.line("yes");
    assert_eq!(
        sim.gotos_sent().len(),
        2,
        "Enter cancelled the pending goto"
    );
    assert!(sim.said(Kind::Info, "Nothing to confirm."));
}

#[test]
fn goto_words_are_checked_and_the_rules_apply() {
    let mut sim = Sim::ready(false);
    for (line, said) in [
        ("goto", "usage: goto az|alt"),
        ("goto up 0.01", "unknown axis \"up\""),
        ("goto az x", "\"x\" isn't a nonzero number"),
        ("goto az 0", "\"0\" isn't a nonzero number"),
        ("goto az 0.01 sideways", "unknown option \"sideways\""),
    ] {
        sim.line(line);
        assert!(sim.said(Kind::Info, said), "{line}: {:#?}", sim.out);
    }
    sim.line("goto az 0.03 fast");
    assert!(sim.said(Kind::Alert, "fast gotos are off"));
    // The approach leg would go 0.18°, past the 0.05° cap.
    sim.line("goto az 0.03 from+");
    assert!(sim.said(Kind::Alert, "a goto leg of 0.1800° exceeds max_goto_deg"));
    assert!(sim.gotos_sent().is_empty());
    assert_eq!(sim.runner.state(), MountState::Armed);
}

#[test]
fn enter_stops_a_goto_and_the_record_shows_where_it_ended() {
    let mut sim = Sim::ready(false);
    sim.line("goto alt +0.05");
    sim.run(200);
    sim.line("");
    sim.run(1_500);
    let record = &sim.runner.controller().records()[0];
    assert_eq!(record.last_stage(), Stage::Cancelled);
    assert!(record.commanded_deg.unwrap() < 0.035);
    assert!(sim.said(Kind::Info, "after the last read before the stop"));
    assert_eq!(sim.runner.adapter().rates_deg_s(), [0.0, 0.0]);
    assert_eq!(sim.runner.state(), MountState::Armed);
}

#[test]
fn enter_stops_a_move_at_once() {
    let mut sim = Sim::ready(false);
    sim.line("alt+ 0.5 2");
    sim.run(500);
    sim.line("");
    assert!(sim.said(Kind::Alert, "STOP sent"));
    sim.run(1500);
    let record = &sim.runner.controller().records()[0];
    assert_eq!(record.last_stage(), Stage::Cancelled);
    assert!(record.commanded_deg.unwrap() < 0.35);
    assert_eq!(sim.runner.adapter().rates_deg_s(), [0.0, 0.0]);
}

#[test]
fn a_reversed_axis_faults_as_opposite_motion_and_stops() {
    let mut sim = Sim::new(
        false,
        SimFaults {
            reverse: true,
            ..SimFaults::default()
        },
    );
    sim.line("yes");
    sim.run(500);
    sim.line("arm");
    sim.line("az+ 0.5 1");
    sim.run(2000);
    assert_eq!(sim.runner.state(), MountState::FaultLatched);
    assert!(sim.said(Kind::Alert, "FAULT OppositeMotion"));
    assert_eq!(sim.runner.adapter().rates_deg_s(), [0.0, 0.0]);
}

#[test]
fn quit_stops_everything_and_finishes() {
    let mut sim = Sim::ready(false);
    sim.line("az- 0.5 2");
    sim.run(300);
    sim.line("quit");
    assert!(sim.runner.finished());
    sim.run(1500);
    assert_eq!(sim.runner.adapter().rates_deg_s(), [0.0, 0.0]);
    let last = sim.runner.adapter().received.last().unwrap();
    assert_eq!(last.1, MountCommand::StopAll);
}

#[test]
fn the_run_log_records_the_session() {
    let mut sim = Sim::ready(false);
    sim.line("az+ 0.3 0.5");
    sim.run(1500);
    let events = sim.log.events();
    for e in [
        "config",
        "operator",
        "checklist",
        "state",
        "request",
        "send",
        "record",
    ] {
        assert!(events.iter().any(|x| x == e), "no {e} in {events:?}");
    }
    assert_eq!(events[0], "config");
}

// --- The live phone path -------------------------------------------------

fn hello() -> Message {
    Message::Hello(Hello {
        protocol_version: PROTOCOL_VERSION,
        session_id: SESSION.into(),
        device: DeviceInfo {
            device_id: DEVICE.into(),
            vendor: "Apple".into(),
            model: "iPhone".into(),
            os_version: "26.0".into(),
            app_version: "1".into(),
            boot_id: "44444444-4444-4444-8444-444444444444".into(),
        },
        sensor_availability: SensorAvailability {
            device_motion: true,
            gyro: true,
            accel: true,
            magnetometer: true,
        },
        streams: vec![Stream::DeviceMotion, Stream::Gyro],
        attitude_reference_frame: AttitudeReferenceFrame::XArbitraryZVertical,
        requested_interval_s: 0.01,
        accel_g0_m_s2: 9.80665,
    })
}

const DEVICE: &str = "22222222-2222-4222-8222-222222222222";

/// The phone clock runs exactly 5 s behind the Mac's.
const PHONE_BEHIND: Nanos = 5_000 * MS;

fn clock_result(index: u64, mac_ns: Nanos) -> Message {
    Message::ClockResult(ClockResult {
        protocol_version: PROTOCOL_VERSION,
        session_id: SESSION.into(),
        device_id: DEVICE.into(),
        exchange_index: index,
        phone_send_ns: mac_ns - PHONE_BEHIND - 2 * MS,
        mac_receive_ns: mac_ns,
        mac_send_ns: mac_ns,
        phone_receive_ns: mac_ns - PHONE_BEHIND + 2 * MS,
        mac_clock_boot_id: MAC_BOOT.into(),
    })
}

/// The phone lies on the tube, top toward the sky end, tube at 30°: its y
/// axis along the tube, z out of the screen. Gravity in body terms, and the
/// body-frame vector for a rotation about the vertical.
const ALT: f64 = 30.0;

fn up_body() -> [f64; 3] {
    let a = ALT.to_radians();
    [0.0, a.sin(), a.cos()]
}

/// The raw gyroscope's offset, rad/s: 0.15 °/s, mostly about the vertical.
fn offset() -> [f64; 3] {
    let b = 0.15f64.to_radians();
    let up = up_body();
    [0.0, b * up[1], b * up[2]]
}

/// Ten samples of each stream ending at `mac_ns`. `azimuth_deg_s` is the
/// true rotation, clockwise from above; the fused rate reports `fused`
/// (iOS's estimate) and the raw gyroscope reports truth plus the offset.
fn batch(mac_ns: Nanos, azimuth_deg_s: f64, fused_deg_s: f64) -> Message {
    let up = up_body();
    let gravity = up.map(|u| -9.80665 * u);
    let about_down = |deg_s: f64| up.map(|u| -deg_s.to_radians() * u);
    let truth = about_down(azimuth_deg_s);
    let b = offset();
    let mut samples = Vec::new();
    for i in 0..10u64 {
        let t_ns = mac_ns - PHONE_BEHIND - (9 - i as i64) * 10 * MS;
        samples.push(Sample::DeviceMotion(DeviceMotionSample {
            seq: 2 * i,
            t_ns,
            attitude: Quaternion {
                w: 1.0,
                x: 0.0,
                y: 0.0,
                z: 0.0,
            },
            rotation_rate: about_down(fused_deg_s),
            gravity,
            user_accel: [0.0; 3],
            magnetic_field_ut: None,
            magnetic_accuracy: None,
        }));
        samples.push(Sample::Gyro(GyroSample {
            seq: 2 * i + 1,
            t_ns,
            rotation_rate: [truth[0] + b[0], truth[1] + b[1], truth[2] + b[2]],
        }));
    }
    Message::SampleBatch(SampleBatch {
        protocol_version: PROTOCOL_VERSION,
        session_id: SESSION.into(),
        device_id: DEVICE.into(),
        first_seq: 0,
        last_seq: 19,
        samples,
    })
}

fn tap(sim: &mut Sim, message: Message) {
    let out = sim.runner.tapped(
        &Tapped {
            message,
            receive_mac_ns: sim.now,
        },
        sim.now,
    );
    sim.out.extend(out);
}

/// Feeds 100 ms batches for `ms`, ticking as it goes.
fn stream(sim: &mut Sim, ms: u64, azimuth_deg_s: f64, fused_deg_s: f64) {
    for _ in 0..ms / 100 {
        sim.now += 100 * MS;
        let now = sim.now;
        tap(sim, batch(now, azimuth_deg_s, fused_deg_s));
        let out = sim.runner.tick(now);
        sim.out.extend(out);
    }
}

fn phone_sim() -> Sim {
    let mut sim = Sim::new(true, SimFaults::default());
    sim.line("yes");
    sim.now = 10_000 * MS;
    tap(&mut sim, hello());
    let now = sim.now;
    tap(&mut sim, clock_result(0, now));
    sim
}

#[test]
fn phone_samples_need_a_clock_model_and_the_tube_altitude_comes_through() {
    let mut sim = Sim::new(true, SimFaults::default());
    sim.line("yes");
    sim.now = 10_000 * MS;
    tap(&mut sim, hello());
    let now = sim.now;
    tap(&mut sim, batch(now, 0.0, 0.0));
    sim.line("status");
    assert!(
        sim.said(Kind::Info, "waiting for a clock model"),
        "no samples are used before the clock is known"
    );
    tap(&mut sim, clock_result(0, now));
    tap(&mut sim, batch(now, 0.0, 0.0));
    sim.line("status");
    assert!(sim.said(Kind::Info, "tube at 30.0°"), "{:#?}", sim.out);
    assert!(sim.said(Kind::Info, "iOS fused rate until armed"));
}

#[test]
fn arming_measures_the_gyro_offset_then_safety_uses_the_raw_gyroscope() {
    let mut sim = phone_sim();
    stream(&mut sim, 1_000, 0.0, 0.0);
    sim.line("arm");
    assert!(sim.said(Kind::Alert, "need 3 s of raw gyroscope data"));
    assert_eq!(sim.runner.state(), MountState::ConnectedReadOnly);

    stream(&mut sim, 3_000, 0.0, 0.0);
    sim.line("arm");
    assert_eq!(sim.runner.state(), MountState::Armed, "{:#?}", sim.out);
    assert!(sim.said(Kind::Info, "raw gyroscope offset"));
    // The 0.15 °/s offset is removed: still means still.
    stream(&mut sim, 1_000, 0.0, 0.0);
    assert_eq!(sim.runner.state(), MountState::Armed, "{:#?}", sim.out);
    sim.line("status");
    assert!(sim.said(Kind::Info, ", raw gyroscope;"));

    // A slow steady turn that iOS's fused rate has absorbed (it reports 0)
    // is still seen through the raw gyroscope: unexpected motion.
    stream(&mut sim, 1_000, 0.3, 0.0);
    assert_eq!(sim.runner.state(), MountState::FaultLatched);
    assert!(
        sim.said(Kind::Alert, "FAULT UnexpectedMotion"),
        "{:#?}",
        sim.out
    );
}

#[test]
fn disarming_clears_the_offset_so_it_is_measured_again() {
    let mut sim = phone_sim();
    stream(&mut sim, 3_500, 0.0, 0.0);
    sim.line("arm");
    assert_eq!(sim.runner.state(), MountState::Armed);
    sim.line("disarm");
    sim.line("status");
    assert!(sim.said(Kind::Info, "iOS fused rate until armed"));
    let events = sim.log.events();
    assert!(events.iter().any(|e| e == "gyro_bias"));
    assert!(events.iter().any(|e| e == "gyro_bias_cleared"));
}

#[test]
fn samples_from_another_session_are_ignored_so_the_imu_goes_stale() {
    let mut sim = phone_sim();
    stream(&mut sim, 3_500, 0.0, 0.0);
    sim.line("arm");
    assert_eq!(sim.runner.state(), MountState::Armed);
    sim.now += 1_500 * MS;
    let Message::SampleBatch(mut other) = batch(sim.now, 0.0, 0.0) else {
        unreachable!()
    };
    other.session_id = "99999999-9999-4999-8999-999999999999".into();
    tap(&mut sim, Message::SampleBatch(other));
    let out = sim.runner.tick(sim.now);
    sim.out.extend(out);
    assert_eq!(sim.runner.state(), MountState::FaultLatched);
    assert!(sim.said(Kind::Alert, "FAULT StaleImu"));
}

// --- Hand controller link health ----------------------------------------

/// The simulated mount, reporting positions only when the test says so,
/// like the Celestron adapter's idle position reads.
struct Reporting {
    mount: SimMount,
    positions: Vec<Position>,
}

impl MountAdapter for Reporting {
    fn send(&mut self, command: &MountCommand, now: Nanos) -> Result<(), TransportError> {
        self.mount.send(command, now)
    }
    fn poll(&mut self, now: Nanos) -> Vec<MountReport> {
        self.mount.poll(now)
    }
}

impl RunnerAdapter for Reporting {
    fn take_positions(&mut self) -> Vec<Position> {
        std::mem::take(&mut self.positions)
    }
    fn reports_positions(&self) -> bool {
        true
    }
}

#[test]
fn arming_needs_a_recent_position_read_and_a_silent_link_is_dropped() {
    let (mut runner, _) = Runner::new(
        config(),
        Reporting {
            mount: SimMount::new(SimFaults::default(), 30.0, 1),
            positions: Vec::new(),
        },
        RunLog::discard(),
        false,
        MAC_BOOT,
        0,
    )
    .unwrap();
    let mut out = runner.line("yes", 0);
    let mut now = 0;
    let mut step = |runner: &mut Runner<Reporting>, ms: u64, read: bool, out: &mut Vec<Out>| {
        for _ in 0..ms / 10 {
            now += 10 * MS;
            if read {
                runner.adapter_mut().positions.push(Position {
                    t_ns: now,
                    deg: [0.0, 30.0],
                });
            }
            let o = runner.adapter_mut().mount.observation(now).unwrap();
            out.extend(runner.observation(o, now));
            out.extend(runner.tick(now));
        }
        now
    };
    // No position has been read yet.
    let t = step(&mut runner, 500, false, &mut out);
    out.extend(runner.line("arm", t));
    assert!(out.iter().any(|o| o.text.contains("hasn't been read yet")));
    assert_eq!(runner.state(), MountState::ConnectedReadOnly);
    // Reads arrive: arming works.
    let t = step(&mut runner, 500, true, &mut out);
    out.extend(runner.line("arm", t));
    assert_eq!(runner.state(), MountState::Armed, "{out:#?}");
    // The reads stop while armed and idle: the link is treated as lost.
    step(&mut runner, 2_000, false, &mut out);
    assert_eq!(runner.state(), MountState::FaultLatched);
    assert!(
        out.iter()
            .any(|o| o.text.contains("stopped answering position reads"))
    );
    assert!(out.iter().any(|o| o.text.contains("FAULT TransportLost")));
}

/// Feeds observations, ticks, and a position every 10 ms from `at(t)`.
fn feed(
    runner: &mut Runner<Reporting>,
    now: &mut Nanos,
    ms: u64,
    at: impl Fn(Nanos) -> [f64; 2],
    out: &mut Vec<Out>,
) {
    for _ in 0..ms / 10 {
        *now += 10 * MS;
        let t = *now;
        runner.adapter_mut().positions.push(Position {
            t_ns: t,
            deg: at(t),
        });
        let o = runner.adapter_mut().mount.observation(t).unwrap();
        out.extend(runner.observation(o, t));
        out.extend(runner.tick(t));
    }
}

fn reporting_runner(phone: bool) -> (Runner<Reporting>, Vec<Out>) {
    let (mut runner, mut out) = Runner::new(
        config(),
        Reporting {
            mount: SimMount::new(SimFaults::default(), 30.0, 1),
            positions: Vec::new(),
        },
        RunLog::discard(),
        false,
        MAC_BOOT,
        0,
    )
    .unwrap();
    out.extend(runner.line("yes", 0));
    if phone {
        out.extend(runner.tapped(
            &Tapped {
                message: hello(),
                receive_mac_ns: 0,
            },
            0,
        ));
    }
    (runner, out)
}

#[test]
fn on_the_mount_a_goto_starts_from_the_last_position_read() {
    for reversed in [false, true] {
        let mut config = config();
        config.celestron.reverse_azimuth = reversed;
        let (mut runner, mut out) = Runner::new(
            config,
            Reporting {
                mount: SimMount::new(SimFaults::default(), 30.0, 1),
                positions: Vec::new(),
            },
            RunLog::discard(),
            false,
            MAC_BOOT,
            0,
        )
        .unwrap();
        out.extend(runner.line("yes", 0));
        let mut now = 0;
        // `z` reads 100 units on the azimuth motor.
        let z = units_to_deg(100);
        feed(&mut runner, &mut now, 600, |_| [z, 30.0], &mut out);
        out.extend(runner.line("arm", now));
        assert_eq!(runner.state(), MountState::Armed, "{out:#?}");
        out.extend(runner.line("goto az +0.002", now));
        let target = runner
            .adapter()
            .mount
            .received
            .iter()
            .find_map(|(_, c)| match c {
                MountCommand::Goto { target, .. } => Some(*target),
                _ => None,
            })
            .unwrap_or_else(|| panic!("{out:#?}"));
        // In axis units: the motor's 100 counts the other way when reversed.
        let start: i64 = if reversed { -100 } else { 100 };
        assert_eq!(target, wrap_units(start + 93), "reversed {reversed}");
        out.extend(runner.line("", now));
    }
}

#[test]
fn positions_either_side_of_zero_count_as_still() {
    let (mut runner, mut out) = reporting_runner(false);
    let mut now = 0;
    // Just after power-on, azimuth reads 359.99998° or 0.00002°.
    feed(
        &mut runner,
        &mut now,
        1_000,
        |t| {
            [
                if (t / MS / 10) % 2 == 0 {
                    359.99998
                } else {
                    0.00002
                },
                0.00002,
            ]
        },
        &mut out,
    );
    out.extend(runner.line("arm", now));
    assert_eq!(runner.state(), MountState::Armed, "{out:#?}");
    feed(
        &mut runner,
        &mut now,
        2_000,
        |t| {
            [
                if (t / MS / 10) % 2 == 0 {
                    359.99998
                } else {
                    0.00002
                },
                0.00002,
            ]
        },
        &mut out,
    );
    assert_eq!(runner.state(), MountState::Armed, "{out:#?}");
}

#[test]
fn a_creep_while_armed_and_idle_latches_unexpected_motion() {
    let (mut runner, mut out) = reporting_runner(false);
    let mut now = 0;
    feed(&mut runner, &mut now, 500, |_| [0.25, 0.03], &mut out);
    out.extend(runner.line("arm", now));
    assert_eq!(runner.state(), MountState::Armed);
    // 0.2″/s on both axes, as seen on 2026-10-29: 0.0003° takes about 5.4 s.
    let start = now;
    let creep = move |t: Nanos| {
        let d = (t - start) as f64 / 1e9 * 0.2 / 3600.0;
        [0.25 + d, 0.03 + d]
    };
    feed(&mut runner, &mut now, 4_000, creep, &mut out);
    assert_eq!(
        runner.state(),
        MountState::Armed,
        "below the threshold so far"
    );
    feed(&mut runner, &mut now, 3_000, creep, &mut out);
    assert_eq!(runner.state(), MountState::FaultLatched);
    assert!(
        out.iter()
            .any(|o| o.text.contains("FAULT UnexpectedMotion") && o.text.contains("while idle")),
        "{out:#?}"
    );
}

/// A runner whose simulated IMU drifts 0.02 °/s in azimuth from 1 s on,
/// as a wandering gyroscope offset would, while the mount stays still.
fn drifting_runner() -> (Runner<Reporting>, Vec<Out>) {
    let (mut runner, mut out) = Runner::new(
        config(),
        Reporting {
            mount: SimMount::new(
                SimFaults {
                    bump: Some((Axis::Azimuth, 0.02, 1_000, 60_000)),
                    ..SimFaults::default()
                },
                30.0,
                1,
            ),
            positions: Vec::new(),
        },
        RunLog::discard(),
        false,
        MAC_BOOT,
        0,
    )
    .unwrap();
    out.extend(runner.line("yes", 0));
    (runner, out)
}

#[test]
fn gyroscope_drift_while_the_positions_hold_is_not_motion() {
    // 0.02 °/s for 20 s integrates to 0.4°, past the 0.25° tolerance; the
    // mount's own positions don't change, so it is drift.
    let (mut runner, mut out) = drifting_runner();
    let mut now = 0;
    feed(&mut runner, &mut now, 600, |_| [0.25, 0.03], &mut out);
    out.extend(runner.line("arm", now));
    assert_eq!(runner.state(), MountState::Armed, "{out:#?}");
    feed(&mut runner, &mut now, 20_000, |_| [0.25, 0.03], &mut out);
    assert_eq!(runner.state(), MountState::Armed, "{out:#?}");

    // Without position reads to say so, the same drift latches.
    let mut sim = Sim::new(
        false,
        SimFaults {
            bump: Some((Axis::Azimuth, 0.02, 1_000, 60_000)),
            ..SimFaults::default()
        },
    );
    sim.line("yes");
    sim.run(500);
    sim.line("arm");
    sim.run(20_000);
    assert_eq!(sim.runner.state(), MountState::FaultLatched);
    assert!(
        sim.said(Kind::Alert, "FAULT UnexpectedMotion: Azimuth turned"),
        "{:#?}",
        sim.out
    );
}

#[test]
fn latched_with_the_positions_holding_drift_raises_no_alarm() {
    let (mut runner, mut out) = drifting_runner();
    let mut now = 0;
    feed(&mut runner, &mut now, 600, |_| [0.25, 0.03], &mut out);
    out.extend(runner.line("arm", now));
    out.extend(runner.line("e", now));
    assert_eq!(runner.state(), MountState::FaultLatched);
    out.clear();
    feed(&mut runner, &mut now, 20_000, |_| [0.25, 0.03], &mut out);
    assert!(
        !out.iter().any(|o| o.text.contains("cut mount power")),
        "{out:#?}"
    );
    out.extend(runner.line("reset", now));
    assert_eq!(runner.state(), MountState::ConnectedReadOnly, "{out:#?}");
}

#[test]
fn a_creep_during_the_offset_window_refuses_arming() {
    let (mut runner, mut out) = reporting_runner(true);
    let now = 10_000 * MS;
    out.extend(runner.tapped(
        &Tapped {
            message: clock_result(0, now),
            receive_mac_ns: now,
        },
        now,
    ));
    let mut t = now;
    for _ in 0..35 {
        t += 100 * MS;
        out.extend(runner.tapped(
            &Tapped {
                message: batch(t, 0.0, 0.0),
                receive_mac_ns: t,
            },
            t,
        ));
        let d = (t - now) as f64 / 1e9 * 0.2 / 3600.0;
        runner.adapter_mut().positions.push(Position {
            t_ns: t,
            deg: [0.25 + d, 0.03 + d],
        });
        out.extend(runner.tick(t));
    }
    out.extend(runner.line("arm", t));
    assert_eq!(runner.state(), MountState::ConnectedReadOnly);
    assert!(
        out.iter().any(|o| o
            .text
            .contains("must be still while the gyroscope offset is measured")),
        "{out:#?}"
    );
}

#[test]
fn a_replaced_adapter_restores_the_link_and_reset_then_arm_works() {
    let (mut runner, mut out) = reporting_runner(false);
    let mut now = 0;
    feed(&mut runner, &mut now, 500, |_| [0.25, 0.03], &mut out);
    out.extend(runner.line("arm", now));
    assert_eq!(runner.state(), MountState::Armed);
    // Position reads stop: the link is treated as lost and latched.
    for _ in 0..200 {
        now += 10 * MS;
        let o = runner.adapter_mut().mount.observation(now).unwrap();
        out.extend(runner.observation(o, now));
        out.extend(runner.tick(now));
    }
    assert_eq!(runner.state(), MountState::FaultLatched);
    // Without the link, reset would leave the session disconnected.
    out.extend(runner.replace_adapter(
        Reporting {
            mount: SimMount::new(SimFaults::default(), 30.0, 1),
            positions: Vec::new(),
        },
        now,
    ));
    assert!(out.iter().any(|o| o.text.contains("link restored")));
    feed(&mut runner, &mut now, 500, |_| [0.25, 0.03], &mut out);
    out.extend(runner.line("reset", now));
    assert_eq!(runner.state(), MountState::ConnectedReadOnly, "{out:#?}");
    out.extend(runner.line("arm", now));
    assert_eq!(runner.state(), MountState::Armed, "{out:#?}");
}

#[test]
fn a_note_goes_into_the_run_log() {
    let mut sim = Sim::new(true, SimFaults::default());
    sim.line("note heard chatter from the altitude motor");
    assert!(sim.said(Kind::Info, "noted"));
    assert!(sim.log.events().iter().any(|e| e == "note"));
}

#[test]
fn commands_are_case_insensitive() {
    let mut sim = Sim::new(false, SimFaults::default());
    sim.line("YES");
    sim.run(500);
    sim.line("ARM");
    assert_eq!(sim.runner.state(), MountState::Armed, "{:#?}", sim.out);
    sim.line("AZ+ 0.2 0.5");
    assert_eq!(sim.moves_sent(), 1);
}

#[test]
fn arming_needs_the_phone_clock_known_to_100_ms() {
    // docs/observations.md O6: a ping that waited 2 s behind a resent backlog.
    let mut sim = Sim::new(true, SimFaults::default());
    sim.line("yes");
    sim.now = 10_000 * MS;
    tap(&mut sim, hello());
    let now = sim.now;
    let Message::ClockResult(mut late) = clock_result(0, now) else {
        unreachable!()
    };
    late.phone_send_ns -= 2_000 * MS;
    tap(&mut sim, Message::ClockResult(late));
    stream(&mut sim, 3_500, 0.0, 0.0);
    sim.line("arm");
    assert!(
        sim.said(Kind::Alert, "only known to ±1002 ms"),
        "{:#?}",
        sim.out
    );
    assert_eq!(sim.runner.state(), MountState::ConnectedReadOnly);

    let now = sim.now;
    tap(&mut sim, clock_result(1, now));
    stream(&mut sim, 3_500, 0.0, 0.0);
    sim.line("arm");
    assert_eq!(sim.runner.state(), MountState::Armed, "{:#?}", sim.out);
}

#[test]
fn samples_mapped_seconds_ahead_are_not_fresh() {
    // A clock model 5 s out that claims to be good: samples land in the
    // future, which must not count as fresh (docs/observations.md O6).
    let mut sim = Sim::new(true, SimFaults::default());
    sim.line("yes");
    sim.now = 10_000 * MS;
    tap(&mut sim, hello());
    let now = sim.now;
    let Message::ClockResult(mut wrong) = clock_result(0, now) else {
        unreachable!()
    };
    wrong.phone_send_ns -= 5_000 * MS;
    wrong.phone_receive_ns -= 5_000 * MS;
    tap(&mut sim, Message::ClockResult(wrong));
    stream(&mut sim, 3_500, 0.0, 0.0);
    sim.line("status");
    assert!(
        sim.said(Kind::Info, "AHEAD (clock model wrong)"),
        "{:#?}",
        sim.out
    );
    sim.line("arm");
    assert_eq!(sim.runner.state(), MountState::ConnectedReadOnly);
}
