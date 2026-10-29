//! Message types. Field names and shapes match `v1.schema.json` exactly.

use serde::{Deserialize, Serialize};

/// Integer nanoseconds in the sender's monotonic clock domain (ADR 0001).
pub type Nanos = i64;

/// Sequence number, one space per (session, device) across all streams.
pub type Seq = u64;

/// `[x, y, z]` in the phone body frame (ADR 0002).
pub type Vec3 = [f64; 3];

/// Hamilton unit quaternion with `w` as the scalar part (ADR 0002).
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Quaternion {
    pub w: f64,
    pub x: f64,
    pub y: f64,
    pub z: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "snake_case")]
pub enum Message {
    Hello(Hello),
    HelloAck(HelloAck),
    SampleBatch(SampleBatch),
    BatchAck(BatchAck),
    ClockPing(ClockPing),
    ClockPong(ClockPong),
    ClockResult(ClockResult),
    Marker(Marker),
    Event(Event),
    Error(ErrorMessage),
    Bye(Bye),
}

impl Message {
    pub fn protocol_version(&self) -> u32 {
        match self {
            Message::Hello(m) => m.protocol_version,
            Message::HelloAck(m) => m.protocol_version,
            Message::SampleBatch(m) => m.protocol_version,
            Message::BatchAck(m) => m.protocol_version,
            Message::ClockPing(m) => m.protocol_version,
            Message::ClockPong(m) => m.protocol_version,
            Message::ClockResult(m) => m.protocol_version,
            Message::Marker(m) => m.protocol_version,
            Message::Event(m) => m.protocol_version,
            Message::Error(m) => m.protocol_version,
            Message::Bye(m) => m.protocol_version,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Hello {
    pub protocol_version: u32,
    pub session_id: String,
    pub device: DeviceInfo,
    pub sensor_availability: SensorAvailability,
    pub streams: Vec<Stream>,
    pub attitude_reference_frame: AttitudeReferenceFrame,
    pub requested_interval_s: f64,
    pub accel_g0_m_s2: f64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceInfo {
    /// Random UUID generated once by the app; not a hardware identifier.
    pub device_id: String,
    pub vendor: String,
    pub model: String,
    pub os_version: String,
    pub app_version: String,
    /// Changes whenever the phone's monotonic clock domain changes.
    pub boot_id: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SensorAvailability {
    pub device_motion: bool,
    pub gyro: bool,
    pub accel: bool,
    pub magnetometer: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Stream {
    DeviceMotion,
    Gyro,
    Accel,
    Magnetometer,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AttitudeReferenceFrame {
    XArbitraryZVertical,
    XArbitraryCorrectedZVertical,
    XMagneticNorthZVertical,
    XTrueNorthZVertical,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct HelloAck {
    pub protocol_version: u32,
    pub session_id: String,
    pub accepted: bool,
    /// `None` when nothing is stored yet; the phone resends everything after it.
    pub highest_contiguous_seq: Option<Seq>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct SampleBatch {
    pub protocol_version: u32,
    pub session_id: String,
    pub device_id: String,
    pub first_seq: Seq,
    pub last_seq: Seq,
    pub samples: Vec<Sample>,
}

impl SampleBatch {
    /// Checks the invariants the schema can't express: samples are in seq
    /// order and cover `first_seq..=last_seq` with no gaps or duplicates.
    pub fn check_contiguous(&self) -> Result<(), String> {
        if self.samples.is_empty() {
            return Err("batch has no samples".into());
        }
        if self.last_seq < self.first_seq {
            return Err(format!(
                "last_seq {} < first_seq {}",
                self.last_seq, self.first_seq
            ));
        }
        for (offset, sample) in self.samples.iter().enumerate() {
            let expected = self.first_seq + offset as Seq;
            if sample.seq() != expected {
                return Err(format!(
                    "sample {offset} has seq {}, expected {expected}",
                    sample.seq()
                ));
            }
        }
        let last = self.samples.last().map(Sample::seq);
        if last != Some(self.last_seq) {
            return Err(format!(
                "last sample seq {last:?} != last_seq {}",
                self.last_seq
            ));
        }
        Ok(())
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "stream", rename_all = "snake_case")]
pub enum Sample {
    DeviceMotion(DeviceMotionSample),
    Gyro(GyroSample),
    Accel(AccelSample),
    Magnetometer(MagnetometerSample),
}

impl Sample {
    pub fn seq(&self) -> Seq {
        match self {
            Sample::DeviceMotion(s) => s.seq,
            Sample::Gyro(s) => s.seq,
            Sample::Accel(s) => s.seq,
            Sample::Magnetometer(s) => s.seq,
        }
    }

    pub fn t_ns(&self) -> Nanos {
        match self {
            Sample::DeviceMotion(s) => s.t_ns,
            Sample::Gyro(s) => s.t_ns,
            Sample::Accel(s) => s.t_ns,
            Sample::Magnetometer(s) => s.t_ns,
        }
    }
}

/// Fused `CMDeviceMotion`. Accelerations in m/s², rates in rad/s.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DeviceMotionSample {
    pub seq: Seq,
    pub t_ns: Nanos,
    /// Rotates phone-body vectors into the session's reference frame.
    pub attitude: Quaternion,
    pub rotation_rate: Vec3,
    pub gravity: Vec3,
    pub user_accel: Vec3,
    /// Always present on the wire; `null` when unavailable.
    pub magnetic_field_ut: Option<Vec3>,
    pub magnetic_accuracy: Option<MagneticAccuracy>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum MagneticAccuracy {
    Uncalibrated,
    Low,
    Medium,
    High,
}

/// Raw `CMGyroData`, rad/s.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct GyroSample {
    pub seq: Seq,
    pub t_ns: Nanos,
    pub rotation_rate: Vec3,
}

/// Raw `CMAccelerometerData`, converted to m/s².
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct AccelSample {
    pub seq: Seq,
    pub t_ns: Nanos,
    pub accel: Vec3,
}

/// Raw `CMMagnetometerData`, µT.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct MagnetometerSample {
    pub seq: Seq,
    pub t_ns: Nanos,
    pub magnetic_field_ut: Vec3,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BatchAck {
    pub protocol_version: u32,
    pub session_id: String,
    pub device_id: String,
    pub highest_contiguous_seq: Seq,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClockPing {
    pub protocol_version: u32,
    pub session_id: String,
    pub device_id: String,
    pub exchange_index: u64,
    pub phone_send_ns: Nanos,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClockPong {
    pub protocol_version: u32,
    pub session_id: String,
    pub exchange_index: u64,
    pub phone_send_ns: Nanos,
    pub mac_receive_ns: Nanos,
    pub mac_send_ns: Nanos,
    /// The receiver run whose clock produced the Mac times (ADR 0001).
    pub mac_clock_boot_id: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ClockResult {
    pub protocol_version: u32,
    pub session_id: String,
    pub device_id: String,
    pub exchange_index: u64,
    pub phone_send_ns: Nanos,
    pub mac_receive_ns: Nanos,
    pub mac_send_ns: Nanos,
    pub phone_receive_ns: Nanos,
    pub mac_clock_boot_id: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Marker {
    pub protocol_version: u32,
    pub session_id: String,
    pub device_id: String,
    pub marker_id: String,
    pub label: String,
    pub t_ns: Nanos,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub notes: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Event {
    pub protocol_version: u32,
    pub session_id: String,
    pub device_id: String,
    pub t_ns: Nanos,
    pub kind: EventKind,
    pub severity: Severity,
    pub detail: serde_json::Map<String, serde_json::Value>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum EventKind {
    ThermalState,
    BatteryState,
    AppState,
    Interruption,
    DroppedSamples,
    BufferPressure,
    EffectiveRate,
    AttitudeDiscontinuity,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Severity {
    Info,
    Warning,
    Error,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ErrorMessage {
    pub protocol_version: u32,
    pub code: ErrorCode,
    pub message: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ErrorCode {
    UnsupportedVersion,
    UnknownSession,
    DeviceMismatch,
    InvalidMessage,
    Internal,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Bye {
    pub protocol_version: u32,
    pub session_id: String,
    pub device_id: String,
    pub last_seq: Option<Seq>,
    pub reason: ByeReason,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ByeReason {
    OperatorStop,
    AppTerminating,
    Error,
}
