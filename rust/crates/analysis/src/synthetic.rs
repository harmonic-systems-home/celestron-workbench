//! Synthetic sessions with known truth for golden tests: poses held still
//! and smooth moves between them, heading drift, noise, gyro bias, missing
//! samples and quaternion sign flips. Sessions are stored through the same
//! `Store` the receiver uses, so the analysis loads them like real data.

use cwb_protocol::{
    AccelSample, AttitudeReferenceFrame, Bye, ByeReason, DeviceInfo, DeviceMotionSample,
    GyroSample, Hello, Marker, Nanos, PROTOCOL_VERSION, Quaternion, STANDARD_GRAVITY_M_S2, Sample,
    SampleBatch, SensorAvailability, Seq, Stream,
};
use cwb_storage::{Connection, Store, StoreConfig, open_in_memory};

use crate::math::{self, Quat};

pub const SESSION: &str = "5e55a0e0-0000-4000-8000-000000000001";
pub const DEVICE: &str = "5e55a0e0-0000-4000-8000-000000000002";
const T0: Nanos = 1_000_000_000_000;

#[derive(Debug, Clone)]
pub struct Scenario {
    pub seconds: f64,
    pub rate_hz: f64,
    /// Attitudes held still over `(start_s, end_s)`, in order; the phone
    /// turns smoothly from one to the next in between.
    pub poses: Vec<(f64, f64, Quat)>,
    pub heading_drift_deg_per_min: f64,
    /// Standard deviation of random attitude jitter, each axis.
    pub attitude_noise_deg: f64,
    pub gyro_bias_rad_s: [f64; 3],
    pub gyro_noise_rad_s: f64,
    pub accel_noise_m_s2: f64,
    /// Sequence numbers never stored (lost in transport).
    pub missing: Vec<(Seq, Seq)>,
    /// Negate every other quaternion (the same rotation).
    pub flip_signs: bool,
    pub markers: Vec<(f64, String)>,
    pub seed: u64,
}

impl Default for Scenario {
    fn default() -> Self {
        Self {
            seconds: 60.0,
            rate_hz: 100.0,
            poses: vec![(0.0, 60.0, [1.0, 0.0, 0.0, 0.0])],
            heading_drift_deg_per_min: 0.0,
            attitude_noise_deg: 0.0,
            gyro_bias_rad_s: [0.0; 3],
            gyro_noise_rad_s: 0.0,
            accel_noise_m_s2: 0.0,
            missing: Vec::new(),
            flip_signs: false,
            markers: Vec::new(),
            seed: 1,
        }
    }
}

/// A rotation of `deg` degrees about `axis`.
pub fn rotation(axis: [f64; 3], deg: f64) -> Quat {
    let a = math::unit(axis);
    let h = deg.to_radians() / 2.0;
    [h.cos(), a[0] * h.sin(), a[1] * h.sin(), a[2] * h.sin()]
}

/// Deterministic normal random numbers (LCG + Box–Muller).
struct Rng(u64);

impl Rng {
    fn uniform(&mut self) -> f64 {
        self.0 = self
            .0
            .wrapping_mul(6_364_136_223_846_793_005)
            .wrapping_add(1_442_695_040_888_963_407);
        ((self.0 >> 11) as f64 + 0.5) / (1u64 << 53) as f64
    }

    fn normal(&mut self) -> f64 {
        let (u, v) = (self.uniform(), self.uniform());
        (-2.0 * u.ln()).sqrt() * (std::f64::consts::TAU * v).cos()
    }
}

fn slerp(a: Quat, b: Quat, f: f64) -> Quat {
    let rel = math::qmul(math::qconj(a), b);
    let (angle, axis) = math::angle_axis(rel);
    math::qmul(a, rotation(axis, (angle * f).to_degrees()))
}

impl Scenario {
    /// Noise-free attitude at time `t` (s).
    pub fn attitude(&self, t: f64) -> Quat {
        let pose = match self.poses.iter().position(|p| t <= p.1) {
            None => self.poses.last().map_or([1.0, 0.0, 0.0, 0.0], |p| p.2),
            Some(0) => self.poses[0].2,
            Some(i) => {
                let (prev, next) = (self.poses[i - 1], self.poses[i]);
                if t >= next.0 {
                    next.2
                } else {
                    let f = (t - prev.1) / (next.0 - prev.1);
                    slerp(prev.2, next.2, f * f * (3.0 - 2.0 * f))
                }
            }
        };
        let drift = rotation([0.0, 0.0, 1.0], self.heading_drift_deg_per_min * t / 60.0);
        math::qmul(drift, pose)
    }

    /// Stores the session in a fresh in-memory database.
    pub fn store(&self) -> Connection {
        let mut store = Store::new(
            open_in_memory().expect("in-memory database"),
            StoreConfig {
                mac_clock_boot_id: "5e55a0e0-0000-4000-8000-0000000000ff".into(),
                software_versions: serde_json::json!({ "synthetic": 1 }),
            },
        );
        store.hello(&self.hello(), 0).expect("hello");
        for batch in self.batches() {
            store.batch(&batch, 0).expect("batch");
        }
        for (i, (t, label)) in self.markers.iter().enumerate() {
            store
                .marker(&Marker {
                    protocol_version: PROTOCOL_VERSION,
                    session_id: SESSION.into(),
                    device_id: DEVICE.into(),
                    marker_id: format!("5e55a0e0-0000-4000-8000-{:012}", 100 + i),
                    label: label.clone(),
                    t_ns: T0 + (t * 1e9) as Nanos,
                    notes: None,
                })
                .expect("marker");
        }
        store
            .bye(
                &Bye {
                    protocol_version: PROTOCOL_VERSION,
                    session_id: SESSION.into(),
                    device_id: DEVICE.into(),
                    last_seq: Some(self.ticks() * 3 - 1),
                    reason: ByeReason::OperatorStop,
                },
                0,
            )
            .expect("bye");
        store.into_connection()
    }

    fn ticks(&self) -> u64 {
        (self.seconds * self.rate_hz).round() as u64
    }

    fn hello(&self) -> Hello {
        Hello {
            protocol_version: PROTOCOL_VERSION,
            session_id: SESSION.into(),
            device: DeviceInfo {
                device_id: DEVICE.into(),
                vendor: "Synthetic".into(),
                model: "synthetic-phone".into(),
                os_version: "0".into(),
                app_version: "synthetic".into(),
                boot_id: "5e55a0e0-0000-4000-8000-000000000003".into(),
            },
            sensor_availability: SensorAvailability {
                device_motion: true,
                gyro: true,
                accel: true,
                magnetometer: false,
            },
            streams: vec![Stream::DeviceMotion, Stream::Gyro, Stream::Accel],
            attitude_reference_frame: AttitudeReferenceFrame::XArbitraryZVertical,
            requested_interval_s: 1.0 / self.rate_hz,
            accel_g0_m_s2: STANDARD_GRAVITY_M_S2,
        }
    }

    fn batches(&self) -> Vec<SampleBatch> {
        let mut rng = Rng(self.seed);
        let dt = 1.0 / self.rate_hz;
        let down = [0.0, 0.0, -STANDARD_GRAVITY_M_S2];
        let missing = |seq: Seq| self.missing.iter().any(|(a, b)| (*a..=*b).contains(&seq));
        let mut batches = Vec::new();
        let mut current: Vec<Sample> = Vec::new();
        let flush = |current: &mut Vec<Sample>, batches: &mut Vec<SampleBatch>| {
            if current.is_empty() {
                return;
            }
            let samples = std::mem::take(current);
            batches.push(SampleBatch {
                protocol_version: PROTOCOL_VERSION,
                session_id: SESSION.into(),
                device_id: DEVICE.into(),
                first_seq: samples[0].seq(),
                last_seq: samples[samples.len() - 1].seq(),
                samples,
            });
        };
        for tick in 0..self.ticks() {
            let t = tick as f64 * dt;
            let t_ns = T0 + (tick as f64 * 1e9 / self.rate_hz).round() as Nanos;
            let q = self.attitude(t);
            let next = self.attitude(t + dt);
            let (angle, axis) = math::angle_axis(math::qmul(math::qconj(q), next));
            let rate = axis.map(|a| a * angle / dt);
            // Attitude jitter: a small rotation vector, in degrees.
            let noise = [
                rng.normal() * self.attitude_noise_deg,
                rng.normal() * self.attitude_noise_deg,
                rng.normal() * self.attitude_noise_deg,
            ];
            let noise_angle = math::norm(noise);
            let measured = if noise_angle > 0.0 {
                math::qmul(q, rotation(noise, noise_angle))
            } else {
                q
            };
            let gravity = math::rotate(math::qconj(measured), down);
            let mut attitude = math::qnorm(measured);
            if self.flip_signs && tick % 2 == 1 {
                attitude = attitude.map(|x| -x);
            }
            let seq = tick * 3;
            let samples = [
                Sample::DeviceMotion(DeviceMotionSample {
                    seq,
                    t_ns,
                    attitude: Quaternion {
                        w: attitude[0],
                        x: attitude[1],
                        y: attitude[2],
                        z: attitude[3],
                    },
                    rotation_rate: rate,
                    gravity,
                    user_accel: [0.0; 3],
                    magnetic_field_ut: None,
                    magnetic_accuracy: None,
                }),
                Sample::Gyro(GyroSample {
                    seq: seq + 1,
                    t_ns,
                    rotation_rate: [0, 1, 2].map(|i| {
                        rate[i] + self.gyro_bias_rad_s[i] + rng.normal() * self.gyro_noise_rad_s
                    }),
                }),
                Sample::Accel(AccelSample {
                    seq: seq + 2,
                    t_ns,
                    accel: [0, 1, 2].map(|i| gravity[i] + rng.normal() * self.accel_noise_m_s2),
                }),
            ];
            for sample in samples {
                if missing(sample.seq()) {
                    flush(&mut current, &mut batches);
                    continue;
                }
                current.push(sample);
            }
            if current.len() >= 30 {
                flush(&mut current, &mut batches);
            }
        }
        flush(&mut current, &mut batches);
        batches
    }
}
