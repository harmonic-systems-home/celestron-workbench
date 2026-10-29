//! A synthetic phone: replays a session log, or a generated session, to a
//! receiver the way the IMU Logger does (handshake, acknowledgements,
//! reconnect, resend), with optional fault injection for tests.

use std::{
    io::BufRead,
    net::SocketAddr,
    time::{Duration, Instant},
};

use cwb_protocol::{
    AccelSample, AttitudeReferenceFrame, Bye, ByeReason, ClockPing, ClockResult, DeviceInfo,
    DeviceMotionSample, ErrorCode, Event, EventKind, GyroSample, Hello, Marker, Message, Nanos,
    PROTOCOL_VERSION, Quaternion, STANDARD_GRAVITY_M_S2, Sample, SampleBatch, SensorAvailability,
    Seq, Severity, Stream,
    framing::{self, Decoder},
};
use thiserror::Error;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpStream, tcp::OwnedReadHalf, tcp::OwnedWriteHalf},
    sync::mpsc,
    time::{sleep, sleep_until, timeout},
};

#[derive(Debug, Error)]
pub enum ClientError {
    #[error("the receiver rejected the session: {0}")]
    Rejected(String),
    #[error("gave up after {0} connections")]
    TooManyConnections(usize),
    #[error("session log: {0}")]
    Log(String),
}

/// Everything a phone would send in one session, in order.
#[derive(Debug, Clone)]
pub struct PhoneSession {
    pub hello: Hello,
    /// Sample batches, markers, events and clock results in the order the
    /// phone sent them.
    pub items: Vec<Message>,
    pub bye: Option<Bye>,
}

impl PhoneSession {
    /// Reads a phone session log (or a `cwb session export`).
    pub fn from_log(input: &mut dyn BufRead) -> Result<Self, ClientError> {
        let mut hello = None;
        let mut items = Vec::new();
        let mut bye = None;
        let lines: Vec<String> = input
            .lines()
            .collect::<Result<_, _>>()
            .map_err(|e| ClientError::Log(e.to_string()))?;
        let total = lines.len();
        for (index, line) in lines.iter().enumerate() {
            if line.trim().is_empty() {
                continue;
            }
            let message: Message = match serde_json::from_str(line) {
                Ok(m) => m,
                // The phone may have been stopped mid-write.
                Err(_) if index + 1 == total => continue,
                Err(e) => return Err(ClientError::Log(format!("line {}: {e}", index + 1))),
            };
            match message {
                Message::Hello(h) if hello.is_none() => hello = Some(h),
                Message::Hello(_) => {
                    return Err(ClientError::Log("more than one hello".into()));
                }
                m @ (Message::SampleBatch(_)
                | Message::Marker(_)
                | Message::Event(_)
                | Message::Site(_)
                | Message::ClockResult(_)) => items.push(m),
                Message::Bye(b) => bye = Some(b),
                _ => {}
            }
        }
        let hello = hello.ok_or_else(|| ClientError::Log("no hello".into()))?;
        Ok(Self { hello, items, bye })
    }

    /// A deterministic bench-like session: device motion, gyro and
    /// accelerometer at `rate_hz`, the phone flat and turning slowly about Z,
    /// sent in batches every 0.1 s.
    pub fn synthetic(seconds: f64, rate_hz: f64) -> Self {
        const OMEGA: f64 = 0.05; // rad/s about +Z
        const T0: Nanos = 1_000_000_000_000;
        let g = STANDARD_GRAVITY_M_S2;
        let session_id = uuid::Uuid::new_v4().to_string();
        let device_id = uuid::Uuid::new_v4().to_string();
        let interval_ns = (1e9 / rate_hz).round() as Nanos;
        let ticks = (seconds * rate_hz).round() as u64;
        let ticks_per_batch = ((rate_hz * 0.1).round() as u64).max(1);

        let hello = Hello {
            protocol_version: PROTOCOL_VERSION,
            session_id: session_id.clone(),
            device: DeviceInfo {
                device_id: device_id.clone(),
                vendor: "Synthetic".into(),
                model: "synthetic-phone".into(),
                os_version: "0".into(),
                app_version: format!("cwb-receiver {}", env!("CARGO_PKG_VERSION")),
                boot_id: uuid::Uuid::new_v4().to_string(),
            },
            sensor_availability: SensorAvailability {
                device_motion: true,
                gyro: true,
                accel: true,
                magnetometer: false,
            },
            streams: vec![Stream::DeviceMotion, Stream::Gyro, Stream::Accel],
            attitude_reference_frame: AttitudeReferenceFrame::XArbitraryZVertical,
            requested_interval_s: 1.0 / rate_hz,
            accel_g0_m_s2: g,
        };

        let mut items = vec![Message::Event(Event {
            protocol_version: PROTOCOL_VERSION,
            session_id: session_id.clone(),
            device_id: device_id.clone(),
            t_ns: T0,
            kind: EventKind::ThermalState,
            severity: Severity::Info,
            detail: serde_json::from_value(serde_json::json!({ "state": "nominal" }))
                .expect("object"),
        })];
        let mut seq: Seq = 0;
        let mut samples = Vec::new();
        for tick in 0..ticks {
            let t_ns = T0 + tick as Nanos * interval_ns;
            let theta = OMEGA * (tick as f64 * interval_ns as f64 / 1e9);
            samples.push(Sample::DeviceMotion(DeviceMotionSample {
                seq,
                t_ns,
                attitude: Quaternion {
                    w: (theta / 2.0).cos(),
                    x: 0.0,
                    y: 0.0,
                    z: (theta / 2.0).sin(),
                },
                rotation_rate: [0.0, 0.0, OMEGA],
                gravity: [0.0, 0.0, -g],
                user_accel: [0.0, 0.0, 0.0],
                magnetic_field_ut: None,
                magnetic_accuracy: None,
            }));
            samples.push(Sample::Gyro(GyroSample {
                seq: seq + 1,
                t_ns,
                rotation_rate: [0.001, -0.002, OMEGA + 0.003],
            }));
            samples.push(Sample::Accel(AccelSample {
                seq: seq + 2,
                t_ns,
                accel: [0.0, 0.0, -g * 1.002],
            }));
            seq += 3;
            if (tick + 1) % ticks_per_batch == 0 || tick + 1 == ticks {
                let batch = std::mem::take(&mut samples);
                items.push(Message::SampleBatch(SampleBatch {
                    protocol_version: PROTOCOL_VERSION,
                    session_id: session_id.clone(),
                    device_id: device_id.clone(),
                    first_seq: batch[0].seq(),
                    last_seq: batch[batch.len() - 1].seq(),
                    samples: batch,
                }));
                if tick + 1 == ticks_per_batch {
                    items.push(Message::Marker(Marker {
                        protocol_version: PROTOCOL_VERSION,
                        session_id: session_id.clone(),
                        device_id: device_id.clone(),
                        marker_id: uuid::Uuid::new_v4().to_string(),
                        label: "synthetic start".into(),
                        t_ns,
                        notes: None,
                    }));
                }
            }
        }
        let bye = Bye {
            protocol_version: PROTOCOL_VERSION,
            session_id,
            device_id,
            last_seq: seq.checked_sub(1),
            reason: ByeReason::OperatorStop,
        };
        Self {
            hello,
            items,
            bye: Some(bye),
        }
    }

    pub fn batches(&self) -> impl Iterator<Item = &SampleBatch> {
        self.items.iter().filter_map(|m| match m {
            Message::SampleBatch(b) => Some(b),
            _ => None,
        })
    }

    pub fn last_seq(&self) -> Option<Seq> {
        self.batches().map(|b| b.last_seq).max()
    }
}

/// Faults to inject, by batch index (0-based, counting only sample batches).
/// Each fires once; the batch is then resent normally after reconnecting.
#[derive(Debug, Clone, Default)]
pub struct Faults {
    /// Drop the connection right after sending this batch.
    pub disconnect_after: Vec<usize>,
    /// Send this batch with a corrupted CRC.
    pub corrupt: Vec<usize>,
    /// Send this batch with a `last_seq` that does not match its samples.
    pub invalid: Vec<usize>,
}

/// Clock exchanges the synthetic phone runs while it sends, against a
/// simulated phone clock: `epoch_phone_ns` at `epoch`, running fast by
/// `drift_ppm`.
#[derive(Debug, Clone)]
pub struct ClockSim {
    pub interval: Duration,
    pub epoch: Instant,
    pub epoch_phone_ns: Nanos,
    pub drift_ppm: f64,
    /// Held back after stamping each ping, as if the phone-to-Mac path were
    /// this much slower than the return path.
    pub outbound_delay: Duration,
}

impl ClockSim {
    pub fn phone_now_ns(&self) -> Nanos {
        self.phone_ns_at(Instant::now())
    }

    pub fn phone_ns_at(&self, instant: Instant) -> Nanos {
        let elapsed = instant.saturating_duration_since(self.epoch).as_nanos() as f64;
        self.epoch_phone_ns + (elapsed * (1.0 + self.drift_ppm / 1e6)).round() as Nanos
    }
}

#[derive(Debug, Clone)]
pub struct ClientOptions {
    /// Replay speed relative to the phone timestamps; `None` sends as fast as possible.
    pub speed: Option<f64>,
    pub faults: Faults,
    /// How long to wait for `hello_ack` or the final `batch_ack`.
    pub ack_timeout: Duration,
    pub retry_delay: Duration,
    pub max_connections: usize,
    pub clock: Option<ClockSim>,
}

impl Default for ClientOptions {
    fn default() -> Self {
        Self {
            speed: None,
            faults: Faults::default(),
            ack_timeout: Duration::from_secs(10),
            retry_delay: Duration::from_millis(250),
            max_connections: 20,
            clock: None,
        }
    }
}

#[derive(Debug, Clone, Default)]
pub struct ClientReport {
    pub connections: usize,
    pub batches_sent: usize,
    pub batches_resent: usize,
    pub acknowledged: Option<Seq>,
    /// What `hello_ack` said on each connection.
    pub resumed_after: Vec<Option<Seq>>,
    /// Errors from the receiver that led to reconnecting.
    pub receiver_errors: Vec<String>,
    pub clock_pings: u64,
    pub clock_results: u64,
}

/// What to do after a message from the receiver.
enum Next {
    Continue,
    Reply(Message),
    Reconnect(String),
}

/// Sends `session` to the receiver at `addr`, reconnecting and resending as
/// needed, and finishes with `bye` once everything is acknowledged.
pub async fn run(
    addr: SocketAddr,
    session: &PhoneSession,
    options: &ClientOptions,
) -> Result<ClientReport, ClientError> {
    let mut report = ClientReport::default();
    let mut faults = options.faults.clone();
    let last_seq = session.last_seq();
    let first_t = session.batches().next().map(|b| b.samples[0].t_ns());
    let started = tokio::time::Instant::now();
    let mut next_item = 0usize;
    let mut next_batch = 0usize;
    let mut attempts = 0usize;
    let mut exchange_index = 0u64;
    let mut next_ping = Instant::now();

    'connect: loop {
        if attempts > 0 {
            sleep(options.retry_delay).await;
        }
        attempts += 1;
        if attempts > options.max_connections {
            return Err(ClientError::TooManyConnections(report.connections));
        }
        let Ok(stream) = TcpStream::connect(addr).await else {
            continue 'connect;
        };
        let _ = stream.set_nodelay(true);
        report.connections += 1;
        let (read, mut write) = stream.into_split();
        let (tx, mut incoming) = mpsc::unbounded_channel();
        let reader = tokio::spawn(read_messages(read, tx));
        let mut connection = Connection {
            write: &mut write,
            reader,
        };

        if connection
            .send(&Message::Hello(session.hello.clone()))
            .await
            .is_err()
        {
            continue 'connect;
        }
        let ack = match timeout(options.ack_timeout, incoming.recv()).await {
            Ok(Some((Message::HelloAck(ack), _))) => ack,
            Ok(Some((Message::Error(e), _))) => {
                on_error(&e.code, &e.message)?;
                report.receiver_errors.push(e.message);
                continue 'connect;
            }
            _ => continue 'connect,
        };
        if !ack.accepted {
            return Err(ClientError::Rejected(
                ack.reason.unwrap_or_else(|| "not accepted".into()),
            ));
        }
        report.resumed_after.push(ack.highest_contiguous_seq);
        report.acknowledged = ack.highest_contiguous_seq;

        // Resend everything sent before but not acknowledged.
        for batch in session.batches().take(next_batch) {
            if report.acknowledged.is_none_or(|a| batch.last_seq > a) {
                if connection
                    .send(&Message::SampleBatch(batch.clone()))
                    .await
                    .is_err()
                {
                    continue 'connect;
                }
                report.batches_resent += 1;
            }
        }

        while next_item < session.items.len() {
            while let Ok((message, arrived)) = incoming.try_recv() {
                match on_message(
                    message,
                    arrived,
                    &mut report,
                    session,
                    options.clock.as_ref(),
                )? {
                    Next::Continue => {}
                    Next::Reply(reply) => {
                        if connection.send(&reply).await.is_err() {
                            continue 'connect;
                        }
                    }
                    Next::Reconnect(reason) => {
                        report.receiver_errors.push(reason);
                        continue 'connect;
                    }
                }
            }
            if let Some(clock) = &options.clock
                && Instant::now() >= next_ping
            {
                next_ping += clock.interval;
                let ping = Message::ClockPing(ClockPing {
                    protocol_version: PROTOCOL_VERSION,
                    session_id: session.hello.session_id.clone(),
                    device_id: session.hello.device.device_id.clone(),
                    exchange_index,
                    phone_send_ns: clock.phone_now_ns(),
                });
                exchange_index += 1;
                if !clock.outbound_delay.is_zero() {
                    sleep(clock.outbound_delay).await;
                }
                if connection.send(&ping).await.is_err() {
                    continue 'connect;
                }
                report.clock_pings += 1;
            }
            let item = &session.items[next_item];
            let Message::SampleBatch(batch) = item else {
                if connection.send(item).await.is_err() {
                    continue 'connect;
                }
                next_item += 1;
                continue;
            };
            if let (Some(speed), Some(t0)) = (options.speed, first_t) {
                let offset = (batch.samples[0].t_ns() - t0).max(0) as f64 / 1e9 / speed;
                sleep_until(started + Duration::from_secs_f64(offset)).await;
            }
            let index = next_batch;
            next_item += 1;
            next_batch += 1;
            if take(&mut faults.corrupt, index) {
                let mut frame = framing::encode(item).expect("encodable");
                frame[6] ^= 0x01;
                let _ = connection.write.write_all(&frame).await;
                report
                    .receiver_errors
                    .extend(drain_until_closed(&mut incoming, options.ack_timeout).await);
                continue 'connect;
            }
            if take(&mut faults.invalid, index) {
                let mut broken = batch.clone();
                broken.last_seq += 1;
                let _ = connection.send(&Message::SampleBatch(broken)).await;
                report
                    .receiver_errors
                    .extend(drain_until_closed(&mut incoming, options.ack_timeout).await);
                continue 'connect;
            }
            if connection.send(item).await.is_err() {
                continue 'connect;
            }
            report.batches_sent += 1;
            if take(&mut faults.disconnect_after, index) {
                connection.reader.abort();
                continue 'connect;
            }
        }

        // Wait for everything to be acknowledged, then say goodbye.
        while last_seq.is_some() && report.acknowledged < last_seq {
            match timeout(options.ack_timeout, incoming.recv()).await {
                Ok(Some((message, arrived))) => {
                    match on_message(
                        message,
                        arrived,
                        &mut report,
                        session,
                        options.clock.as_ref(),
                    )? {
                        Next::Continue => {}
                        Next::Reply(reply) => {
                            if connection.send(&reply).await.is_err() {
                                continue 'connect;
                            }
                        }
                        Next::Reconnect(reason) => {
                            report.receiver_errors.push(reason);
                            continue 'connect;
                        }
                    }
                }
                _ => continue 'connect,
            }
        }
        let bye = session.bye.clone().unwrap_or_else(|| Bye {
            protocol_version: PROTOCOL_VERSION,
            session_id: session.hello.session_id.clone(),
            device_id: session.hello.device.device_id.clone(),
            last_seq,
            reason: ByeReason::OperatorStop,
        });
        if connection.send(&Message::Bye(bye)).await.is_err() {
            continue 'connect;
        }
        let _ = connection.write.shutdown().await;
        drain_until_closed(&mut incoming, options.ack_timeout).await;
        return Ok(report);
    }
}

struct Connection<'a> {
    write: &'a mut OwnedWriteHalf,
    reader: tokio::task::JoinHandle<()>,
}

impl Connection<'_> {
    async fn send(&mut self, message: &Message) -> std::io::Result<()> {
        let frame = framing::encode(message).map_err(std::io::Error::other)?;
        self.write.write_all(&frame).await
    }
}

impl Drop for Connection<'_> {
    fn drop(&mut self) {
        self.reader.abort();
    }
}

fn take(list: &mut Vec<usize>, index: usize) -> bool {
    if let Some(position) = list.iter().position(|&i| i == index) {
        list.remove(position);
        true
    } else {
        false
    }
}

fn on_message(
    message: Message,
    arrived: Instant,
    report: &mut ClientReport,
    session: &PhoneSession,
    clock: Option<&ClockSim>,
) -> Result<Next, ClientError> {
    match message {
        Message::BatchAck(ack) => {
            report.acknowledged = report.acknowledged.max(Some(ack.highest_contiguous_seq));
            Ok(Next::Continue)
        }
        Message::ClockPong(pong) => {
            let Some(clock) = clock else {
                return Ok(Next::Continue);
            };
            report.clock_results += 1;
            Ok(Next::Reply(Message::ClockResult(ClockResult {
                protocol_version: PROTOCOL_VERSION,
                session_id: pong.session_id,
                device_id: session.hello.device.device_id.clone(),
                exchange_index: pong.exchange_index,
                phone_send_ns: pong.phone_send_ns,
                mac_receive_ns: pong.mac_receive_ns,
                mac_send_ns: pong.mac_send_ns,
                phone_receive_ns: clock.phone_ns_at(arrived),
                mac_clock_boot_id: pong.mac_clock_boot_id,
            })))
        }
        Message::Error(e) => on_error(&e.code, &e.message),
        _ => Ok(Next::Continue),
    }
}

/// Same policy as the phone's `Uplink`: some errors are final, the rest retry.
fn on_error(code: &ErrorCode, message: &str) -> Result<Next, ClientError> {
    match code {
        ErrorCode::UnsupportedVersion | ErrorCode::DeviceMismatch | ErrorCode::UnknownSession => {
            Err(ClientError::Rejected(format!("{code:?}: {message}")))
        }
        ErrorCode::InvalidMessage | ErrorCode::Internal => Ok(Next::Reconnect(message.into())),
    }
}

/// Reads until the receiver closes the connection, so a refused message
/// is seen to be refused before reconnecting. Returns any error messages.
async fn drain_until_closed(
    incoming: &mut mpsc::UnboundedReceiver<(Message, Instant)>,
    limit: Duration,
) -> Vec<String> {
    let deadline = Instant::now() + limit;
    let mut errors = Vec::new();
    while let Ok(Some(message)) = timeout(
        deadline.saturating_duration_since(Instant::now()),
        incoming.recv(),
    )
    .await
    {
        if let (Message::Error(e), _) = message {
            errors.push(e.message);
        }
    }
    errors
}

/// Forwards each message with the time it was read, so clock exchanges are
/// stamped on arrival rather than when the send loop gets to them.
async fn read_messages(mut read: OwnedReadHalf, tx: mpsc::UnboundedSender<(Message, Instant)>) {
    let mut decoder = Decoder::new();
    let mut buf = vec![0u8; 16 * 1024];
    loop {
        match read.read(&mut buf).await {
            Ok(0) | Err(_) => return,
            Ok(n) => decoder.push(&buf[..n]),
        }
        let arrived = Instant::now();
        loop {
            match decoder.next_message() {
                Ok(Some(message)) => {
                    if tx.send((message, arrived)).is_err() {
                        return;
                    }
                }
                Ok(None) => break,
                Err(_) => return,
            }
        }
    }
}
