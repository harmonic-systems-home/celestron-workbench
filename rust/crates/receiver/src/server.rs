//! The TCP receiver (ADR 0004, ADR 0006).
//!
//! Each connection is one task that reads frames, validates them against the
//! schema, hands them to the database writer, and acknowledges the highest
//! contiguous seq once the writer has committed. Anything malformed gets an
//! `error` and the connection is closed; the phone reconnects and resends.

use std::{
    future::Future,
    net::SocketAddr,
    sync::Arc,
    time::{Duration, Instant},
};

use cwb_protocol::{
    BatchAck, ClockPong, ErrorCode, ErrorMessage, HelloAck, Message, PROTOCOL_VERSION, Seq,
    framing::{self, Decoder},
};
use cwb_storage::{HelloOutcome, MacClock, StorageError};
use serde_json::json;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream, tcp::OwnedWriteHalf},
    sync::mpsc,
    task::JoinSet,
};

use crate::writer::{WriterError, WriterHandle};

/// The port in ADR 0004.
pub const DEFAULT_PORT: u16 = 47800;

/// How often a connection logs its progress.
const PROGRESS_INTERVAL: Duration = Duration::from_secs(10);

/// A copy of a phone message for a live consumer (the mount runner), with
/// the Mac time it arrived. Only `hello`, sample batches and clock results
/// are copied.
#[derive(Debug, Clone)]
pub struct Tapped {
    pub message: Message,
    pub receive_mac_ns: i64,
}

pub struct Server {
    listener: TcpListener,
    writer: WriterHandle,
    clock: Arc<MacClock>,
    tap: Option<mpsc::Sender<Tapped>>,
}

impl Server {
    pub async fn bind(
        addr: SocketAddr,
        writer: WriterHandle,
        clock: Arc<MacClock>,
    ) -> std::io::Result<Self> {
        Ok(Self {
            listener: TcpListener::bind(addr).await?,
            writer,
            clock,
            tap: None,
        })
    }

    /// Also sends a copy of each valid phone message to `tap`. A full tap
    /// drops the copy rather than slowing storage: the consumer sees a gap.
    pub fn with_tap(mut self, tap: mpsc::Sender<Tapped>) -> Self {
        self.tap = Some(tap);
        self
    }

    pub fn local_addr(&self) -> std::io::Result<SocketAddr> {
        self.listener.local_addr()
    }

    /// Accepts connections until `shutdown` completes, then closes them all.
    pub async fn run(self, shutdown: impl Future<Output = ()>) {
        let mut connections = JoinSet::new();
        tokio::pin!(shutdown);
        loop {
            tokio::select! {
                () = &mut shutdown => break,
                accepted = self.listener.accept() => match accepted {
                    Ok((stream, _)) => {
                        let _ = stream.set_nodelay(true);
                        let connection = Connection::new(
                            self.writer.clone(),
                            self.clock.clone(),
                            self.tap.clone(),
                        );
                        connections.spawn(connection.run(stream));
                    }
                    Err(e) => tracing::warn!("accept failed: {e}"),
                },
                Some(_) = connections.join_next(), if !connections.is_empty() => {}
            }
        }
        connections.shutdown().await;
    }
}

/// Why a connection ended.
enum Close {
    /// The phone sent `bye`.
    Bye,
    /// The phone closed the socket or it failed.
    Lost(String),
    /// We closed it after sending an `error`.
    Refused(ErrorCode, String),
}

struct Connection {
    writer: WriterHandle,
    clock: Arc<MacClock>,
    tap: Option<mpsc::Sender<Tapped>>,
    /// Session and device after an accepted `hello`.
    session: Option<(String, String)>,
    stored: u64,
    acknowledged: Option<Seq>,
    last_progress: Instant,
    stored_at_last_progress: u64,
}

impl Connection {
    fn new(writer: WriterHandle, clock: Arc<MacClock>, tap: Option<mpsc::Sender<Tapped>>) -> Self {
        Self {
            writer,
            clock,
            tap,
            session: None,
            stored: 0,
            acknowledged: None,
            last_progress: Instant::now(),
            stored_at_last_progress: 0,
        }
    }

    async fn run(mut self, stream: TcpStream) {
        let (mut read, mut write) = stream.into_split();
        let mut decoder = Decoder::new();
        let mut buf = vec![0u8; 64 * 1024];
        let close = 'connection: loop {
            let n = match read.read(&mut buf).await {
                Ok(0) => break Close::Lost("phone closed the connection".into()),
                Ok(n) => n,
                Err(e) => break Close::Lost(e.to_string()),
            };
            // Everything in this read arrived now, even if it waits behind
            // a database commit before it is handled.
            let receive_mac_ns = self.clock.now_ns();
            decoder.push(&buf[..n]);
            loop {
                let payload = match decoder.next_payload() {
                    Ok(Some(p)) => p,
                    Ok(None) => break,
                    Err(e) => {
                        break 'connection Close::Refused(ErrorCode::InvalidMessage, e.to_string());
                    }
                };
                match self.handle(&payload, receive_mac_ns, &mut write).await {
                    Ok(None) => {}
                    Ok(Some(close)) => break 'connection close,
                    Err(e) => break 'connection Close::Lost(e.to_string()),
                }
            }
        };
        self.closed(close, &mut write).await;
    }

    /// Handles one payload. Returns `Some` when the connection should close.
    async fn handle(
        &mut self,
        payload: &[u8],
        receive_mac_ns: i64,
        write: &mut OwnedWriteHalf,
    ) -> std::io::Result<Option<Close>> {
        let value: serde_json::Value = match serde_json::from_slice(payload) {
            Ok(v) => v,
            Err(e) => {
                return Ok(Some(refuse(
                    ErrorCode::InvalidMessage,
                    format!("not JSON: {e}"),
                )));
            }
        };
        if let Some(version) = value.get("protocol_version").and_then(|v| v.as_u64())
            && version != u64::from(PROTOCOL_VERSION)
        {
            return Ok(Some(refuse(
                ErrorCode::UnsupportedVersion,
                format!(
                    "protocol version {version} is not supported (expected {PROTOCOL_VERSION})"
                ),
            )));
        }
        if let Err(errors) = cwb_protocol::schema::validate(&value) {
            return Ok(Some(refuse(ErrorCode::InvalidMessage, errors.join("; "))));
        }
        let message: Message = match serde_json::from_value(value) {
            Ok(m) => m,
            Err(e) => return Ok(Some(refuse(ErrorCode::InvalidMessage, e.to_string()))),
        };
        if let Some(tap) = &self.tap
            && matches!(
                message,
                Message::Hello(_) | Message::SampleBatch(_) | Message::ClockResult(_)
            )
        {
            let _ = tap.try_send(Tapped {
                message: message.clone(),
                receive_mac_ns,
            });
        }

        match message {
            Message::Hello(hello) => {
                if let Some((session, _)) = &self.session {
                    return Ok(Some(refuse(
                        ErrorCode::InvalidMessage,
                        format!("second hello on a connection already in session {session}"),
                    )));
                }
                let session_id = hello.session_id.clone();
                let device_id = hello.device.device_id.clone();
                match self.writer.hello(hello, receive_mac_ns).await {
                    Ok(HelloOutcome::Accepted {
                        created,
                        highest_contiguous_seq,
                    }) => {
                        tracing::info!(
                            session = short(&session_id),
                            resume_after = ?highest_contiguous_seq,
                            "{}",
                            if created { "new session" } else { "phone reconnected" }
                        );
                        self.acknowledged = highest_contiguous_seq;
                        self.session = Some((session_id.clone(), device_id));
                        send(
                            write,
                            &Message::HelloAck(HelloAck {
                                protocol_version: PROTOCOL_VERSION,
                                session_id,
                                accepted: true,
                                highest_contiguous_seq,
                                reason: None,
                            }),
                        )
                        .await?;
                    }
                    Ok(HelloOutcome::Rejected { code, reason }) => {
                        return Ok(Some(refuse(code, reason)));
                    }
                    Err(e) => return Ok(Some(self.writer_failed(e))),
                }
            }
            Message::SampleBatch(batch) => {
                if let Some(close) = self.check_session(&batch.session_id, &batch.device_id) {
                    return Ok(Some(close));
                }
                let (first, last) = (batch.first_seq, batch.last_seq);
                match self.writer.batch(batch, receive_mac_ns).await {
                    Ok(outcome) => {
                        self.stored += outcome.stored as u64;
                        if let Some((expected, got)) = outcome.gap {
                            tracing::warn!(
                                session = self.short_session(),
                                "sequence gap: expected {expected}, batch starts at {got}"
                            );
                        }
                        if outcome.conflicts > 0 {
                            tracing::error!(
                                session = self.short_session(),
                                "{} samples in {first}..={last} conflict with stored ones",
                                outcome.conflicts
                            );
                        }
                        if let Some(highest) = outcome.highest_contiguous_seq {
                            self.acknowledged = Some(highest);
                            let (session_id, device_id) = self.session.clone().unwrap_or_default();
                            send(
                                write,
                                &Message::BatchAck(BatchAck {
                                    protocol_version: PROTOCOL_VERSION,
                                    session_id,
                                    device_id,
                                    highest_contiguous_seq: highest,
                                }),
                            )
                            .await?;
                        }
                        self.log_progress();
                    }
                    Err(WriterError::Storage(StorageError::InvalidMessage(reason))) => {
                        return Ok(Some(refuse(ErrorCode::InvalidMessage, reason)));
                    }
                    Err(e) => return Ok(Some(self.writer_failed(e))),
                }
            }
            Message::Marker(marker) => {
                if let Some(close) = self.check_session(&marker.session_id, &marker.device_id) {
                    return Ok(Some(close));
                }
                tracing::info!(session = self.short_session(), label = %marker.label, "marker");
                if let Err(e) = self.writer.marker(marker).await {
                    return Ok(Some(self.writer_failed(e)));
                }
            }
            Message::Event(event) => {
                if let Some(close) = self.check_session(&event.session_id, &event.device_id) {
                    return Ok(Some(close));
                }
                if !matches!(event.severity, cwb_protocol::Severity::Info) {
                    tracing::warn!(
                        session = self.short_session(),
                        kind = ?event.kind,
                        detail = %serde_json::Value::Object(event.detail.clone()),
                        "phone event"
                    );
                }
                if let Err(e) = self.writer.event(event, receive_mac_ns).await {
                    return Ok(Some(self.writer_failed(e)));
                }
            }
            Message::Site(site) => {
                if let Some(close) = self.check_session(&site.session_id, &site.device_id) {
                    return Ok(Some(close));
                }
                // Never the coordinates: logs aren't private storage.
                tracing::info!(
                    session = self.short_session(),
                    environment = ?site.environment,
                    location = ?site.location_status,
                    "site"
                );
                match self.writer.site(site, receive_mac_ns).await {
                    Ok(_) => {}
                    Err(WriterError::Storage(StorageError::InvalidMessage(reason))) => {
                        return Ok(Some(refuse(ErrorCode::InvalidMessage, reason)));
                    }
                    Err(e) => return Ok(Some(self.writer_failed(e))),
                }
            }
            Message::Bye(bye) => {
                if let Some(close) = self.check_session(&bye.session_id, &bye.device_id) {
                    return Ok(Some(close));
                }
                match self.writer.bye(bye, receive_mac_ns).await {
                    Ok(outcome) => {
                        tracing::info!(
                            session = self.short_session(),
                            stored_contiguously_to = ?outcome.highest_contiguous_seq,
                            "session {}",
                            if outcome.complete { "ended" } else { "ended incomplete" }
                        );
                        return Ok(Some(Close::Bye));
                    }
                    Err(e) => return Ok(Some(self.writer_failed(e))),
                }
            }
            // Answered straight away, before anything else is read, so the
            // Mac turnaround stays short; it is excluded from the round trip.
            Message::ClockPing(ping) => {
                if let Some(close) = self.check_session(&ping.session_id, &ping.device_id) {
                    return Ok(Some(close));
                }
                send(
                    write,
                    &Message::ClockPong(ClockPong {
                        protocol_version: PROTOCOL_VERSION,
                        session_id: ping.session_id,
                        exchange_index: ping.exchange_index,
                        phone_send_ns: ping.phone_send_ns,
                        mac_receive_ns: receive_mac_ns,
                        mac_send_ns: self.clock.now_ns(),
                        mac_clock_boot_id: self.clock.boot_id().to_owned(),
                    }),
                )
                .await?;
            }
            Message::ClockResult(result) => {
                if let Some(close) = self.check_session(&result.session_id, &result.device_id) {
                    return Ok(Some(close));
                }
                match self.writer.clock_result(result).await {
                    Ok(_) => {}
                    Err(WriterError::Storage(StorageError::InvalidMessage(reason))) => {
                        return Ok(Some(refuse(ErrorCode::InvalidMessage, reason)));
                    }
                    Err(e) => return Ok(Some(self.writer_failed(e))),
                }
            }
            Message::HelloAck(_)
            | Message::BatchAck(_)
            | Message::ClockPong(_)
            | Message::Error(_) => {
                return Ok(Some(refuse(
                    ErrorCode::InvalidMessage,
                    "the receiver does not accept receiver-to-phone messages".into(),
                )));
            }
        }
        Ok(None)
    }

    /// Requires an accepted `hello` for the same session and device.
    fn check_session(&self, session_id: &str, device_id: &str) -> Option<Close> {
        match &self.session {
            None => Some(refuse(
                ErrorCode::UnknownSession,
                format!("no hello for session {session_id} on this connection"),
            )),
            Some((s, d)) if s != session_id || d != device_id => Some(refuse(
                ErrorCode::InvalidMessage,
                format!("message for session {session_id} on a connection for session {s}"),
            )),
            Some(_) => None,
        }
    }

    fn writer_failed(&self, error: WriterError) -> Close {
        tracing::error!("database writer failed: {error}");
        refuse(
            ErrorCode::Internal,
            "the receiver could not store the message".into(),
        )
    }

    fn log_progress(&mut self) {
        let elapsed = self.last_progress.elapsed();
        if elapsed < PROGRESS_INTERVAL {
            return;
        }
        let new = self.stored - self.stored_at_last_progress;
        tracing::info!(
            session = self.short_session(),
            stored = self.stored,
            acknowledged = ?self.acknowledged,
            "{:.1} samples/s",
            new as f64 / elapsed.as_secs_f64()
        );
        self.last_progress = Instant::now();
        self.stored_at_last_progress = self.stored;
    }

    fn short_session(&self) -> &str {
        self.session.as_ref().map_or("-", |(s, _)| short(s))
    }

    async fn closed(self, close: Close, write: &mut OwnedWriteHalf) {
        let now = self.clock.now_ns();
        let (kind, severity, detail) = match &close {
            Close::Bye => ("connection_closed", "info", json!({ "reason": "bye" })),
            Close::Lost(reason) => {
                tracing::warn!(session = self.short_session(), "connection lost: {reason}");
                ("connection_lost", "warning", json!({ "reason": reason }))
            }
            Close::Refused(code, reason) => {
                tracing::warn!(session = self.short_session(), ?code, "refused: {reason}");
                let _ = send(
                    write,
                    &Message::Error(ErrorMessage {
                        protocol_version: PROTOCOL_VERSION,
                        code: *code,
                        message: reason.clone(),
                    }),
                )
                .await;
                (
                    "message_refused",
                    "error",
                    json!({ "code": code, "reason": reason }),
                )
            }
        };
        let _ = write.shutdown().await;
        if let Some((session, device)) = &self.session {
            self.writer
                .mac_event(
                    session,
                    Some(device),
                    kind,
                    severity,
                    json!({
                        "detail": detail,
                        "stored_on_connection": self.stored,
                        "acknowledged": self.acknowledged,
                    }),
                    now,
                )
                .await;
        }
    }
}

fn refuse(code: ErrorCode, reason: String) -> Close {
    Close::Refused(code, reason)
}

async fn send(write: &mut OwnedWriteHalf, message: &Message) -> std::io::Result<()> {
    let frame = framing::encode(message).map_err(std::io::Error::other)?;
    write.write_all(&frame).await
}

fn short(id: &str) -> &str {
    id.get(..8).unwrap_or(id)
}
