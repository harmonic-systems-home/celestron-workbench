//! The runner core against the simulated mount, on simulated time: the
//! checklist gate, first-move confirmation, Enter as stop, quitting, the
//! live phone path (tap, clock model, axis conversion) and the run log.

use std::{
    io::Write,
    sync::{Arc, Mutex},
};

use cwb_mount_core::{MountCommand, MountState, Nanos, Stage};
use cwb_mount_runner::{Kind, Out, RunLog, Runner, RunnerConfig};
use cwb_mount_sim::{SimFaults, SimMount};
use cwb_protocol::{
    AttitudeReferenceFrame, ClockResult, DeviceInfo, DeviceMotionSample, Hello, Message,
    PROTOCOL_VERSION, Quaternion, Sample, SampleBatch, SensorAvailability, Stream,
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
            device_id: "22222222-2222-4222-8222-222222222222".into(),
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
        streams: vec![Stream::DeviceMotion],
        attitude_reference_frame: AttitudeReferenceFrame::XArbitraryZVertical,
        requested_interval_s: 0.01,
        accel_g0_m_s2: 9.80665,
    })
}

/// The phone clock runs exactly 5 s behind the Mac's.
const PHONE_BEHIND: Nanos = 5_000 * MS;

fn clock_result(index: u64, mac_ns: Nanos) -> Message {
    Message::ClockResult(ClockResult {
        protocol_version: PROTOCOL_VERSION,
        session_id: SESSION.into(),
        device_id: "22222222-2222-4222-8222-222222222222".into(),
        exchange_index: index,
        phone_send_ns: mac_ns - PHONE_BEHIND - 2 * MS,
        mac_receive_ns: mac_ns,
        mac_send_ns: mac_ns,
        phone_receive_ns: mac_ns - PHONE_BEHIND + 2 * MS,
        mac_clock_boot_id: MAC_BOOT.into(),
    })
}

/// A still phone, top toward the sky end, tube at 30° altitude.
fn batch(mac_ns: Nanos) -> Message {
    let alt = 30f64.to_radians();
    // Phone y along the tube, z up-ish: gravity in body terms.
    let gravity = [0.0, -9.80665 * alt.sin(), -9.80665 * alt.cos()];
    let samples = (0..10)
        .map(|i| {
            Sample::DeviceMotion(DeviceMotionSample {
                seq: i,
                t_ns: mac_ns - PHONE_BEHIND - (9 - i as i64) * 10 * MS,
                attitude: Quaternion {
                    w: 1.0,
                    x: 0.0,
                    y: 0.0,
                    z: 0.0,
                },
                rotation_rate: [0.0; 3],
                gravity,
                user_accel: [0.0; 3],
                magnetic_field_ut: None,
                magnetic_accuracy: None,
            })
        })
        .collect();
    Message::SampleBatch(SampleBatch {
        protocol_version: PROTOCOL_VERSION,
        session_id: SESSION.into(),
        device_id: "22222222-2222-4222-8222-222222222222".into(),
        first_seq: 0,
        last_seq: 9,
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

#[test]
fn phone_samples_reach_the_controller_through_the_clock_model() {
    let mut sim = Sim::new(true, SimFaults::default());
    sim.line("yes");
    sim.now = 10_000 * MS;
    let now = sim.now;
    tap(&mut sim, hello());
    tap(&mut sim, batch(now));
    sim.line("status");
    assert!(
        sim.said(Kind::Info, "waiting for a clock model"),
        "no samples are used before the clock is known"
    );
    tap(&mut sim, clock_result(0, now));
    tap(&mut sim, batch(now));
    sim.line("status");
    assert!(sim.said(Kind::Info, "tube at 30.0°"), "{:#?}", sim.out);
    sim.line("arm");
    assert_eq!(sim.runner.state(), MountState::Armed, "{:#?}", sim.out);
    // Samples from another session are ignored, so the IMU goes stale.
    sim.now += 1_500 * MS;
    let Message::SampleBatch(mut other) = batch(sim.now) else {
        unreachable!()
    };
    other.session_id = "99999999-9999-4999-8999-999999999999".into();
    tap(&mut sim, Message::SampleBatch(other));
    let out = sim.runner.tick(sim.now);
    sim.out.extend(out);
    assert_eq!(sim.runner.state(), MountState::FaultLatched);
    assert!(sim.said(Kind::Alert, "FAULT StaleImu"));
}
