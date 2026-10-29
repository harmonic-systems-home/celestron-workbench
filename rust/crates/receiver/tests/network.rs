//! End-to-end tests: a synthetic phone talking to the receiver over loopback,
//! including dropped connections, corrupted frames, refused batches and a
//! receiver restart in the middle of a session.

use std::{
    net::SocketAddr,
    path::{Path, PathBuf},
    sync::Arc,
    thread::JoinHandle,
    time::Duration,
};

use cwb_protocol::{
    ErrorCode, Message, PROTOCOL_VERSION,
    framing::{self, Decoder},
};
use cwb_receiver::{
    Server,
    client::{self, ClientError, ClientOptions, Faults, PhoneSession},
    writer::{self, WriterHandle},
};
use cwb_storage::{Connection, MacClock, Store, StoreConfig, sessions};
use serde_json::json;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
    sync::oneshot,
    task::JoinHandle as TaskHandle,
    time::timeout,
};

struct Receiver {
    addr: SocketAddr,
    writer: WriterHandle,
    stop: oneshot::Sender<()>,
    server: TaskHandle<()>,
    thread: JoinHandle<Store>,
}

async fn start(db: &Path, queue: usize) -> Receiver {
    let clock = Arc::new(MacClock::new());
    let (conn, _) = cwb_storage::open(db).unwrap();
    let store = Store::new(
        conn,
        StoreConfig {
            mac_clock_boot_id: clock.boot_id().to_owned(),
            software_versions: json!({ "test": "1" }),
        },
    );
    let (writer, thread) = writer::spawn(store, queue);
    let server = Server::bind(([127, 0, 0, 1], 0).into(), writer.clone(), clock)
        .await
        .unwrap();
    let addr = server.local_addr().unwrap();
    let (stop, stopped) = oneshot::channel();
    let server = tokio::spawn(server.run(async {
        let _ = stopped.await;
    }));
    Receiver {
        addr,
        writer,
        stop,
        server,
        thread,
    }
}

impl Receiver {
    /// Stops like Ctrl-C does; returns the sessions marked incomplete.
    async fn stop(self) -> Vec<String> {
        let _ = self.stop.send(());
        self.server.await.unwrap();
        let marked = self
            .writer
            .shutdown("receiver stopped before bye")
            .await
            .unwrap();
        drop(self.writer);
        tokio::task::spawn_blocking(move || self.thread.join().unwrap())
            .await
            .unwrap();
        marked
    }
}

fn temp_db() -> (tempfile::TempDir, PathBuf) {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("test.sqlite");
    (dir, path)
}

fn read(db: &Path) -> Connection {
    cwb_storage::open_read_only(db).unwrap()
}

fn fast() -> ClientOptions {
    ClientOptions {
        retry_delay: Duration::from_millis(20),
        ack_timeout: Duration::from_secs(5),
        ..ClientOptions::default()
    }
}

fn mac_events(conn: &Connection, kind: &str) -> i64 {
    conn.query_row(
        "SELECT COUNT(*) FROM session_events WHERE source = 'mac' AND kind = ?1",
        [kind],
        |r| r.get(0),
    )
    .unwrap()
}

/// Asserts the stored session is complete and has exactly the phone's samples.
fn assert_complete(db: &Path, phone: &PhoneSession) -> sessions::SessionReport {
    let conn = read(db);
    let report = sessions::validate(&conn, &phone.hello.session_id).unwrap();
    assert!(report.problems.is_empty(), "{:?}", report.problems);
    assert_eq!(report.session.status, "ended");
    let expected: usize = phone.batches().map(|b| b.samples.len()).sum();
    assert_eq!(report.session.samples as usize, expected);
    assert_eq!(report.devices[0].last_seq, phone.last_seq());
    report
}

#[tokio::test]
async fn a_synthetic_session_is_stored_completely() {
    let (_dir, db) = temp_db();
    let receiver = start(&db, 64).await;
    let phone = PhoneSession::synthetic(5.0, 100.0);
    let report = client::run(receiver.addr, &phone, &fast()).await.unwrap();
    assert_eq!(report.connections, 1);
    assert_eq!(report.acknowledged, phone.last_seq());
    assert_eq!(report.resumed_after, vec![None]);
    assert!(receiver.stop().await.is_empty());

    let stored = assert_complete(&db, &phone);
    assert_eq!(stored.session.markers, 1);
    let gyro = stored.devices[0]
        .streams
        .iter()
        .find(|s| s.stream == "gyro")
        .unwrap();
    assert!((gyro.rate_hz.unwrap() - 100.0).abs() < 1e-6);

    // The export replays to a fresh receiver and is stored identically.
    let mut exported = Vec::new();
    sessions::export(&read(&db), &phone.hello.session_id, &mut exported).unwrap();
    let replayed = PhoneSession::from_log(&mut exported.as_slice()).unwrap();
    let (_dir2, db2) = temp_db();
    let second = start(&db2, 64).await;
    client::run(second.addr, &replayed, &fast()).await.unwrap();
    second.stop().await;
    assert_complete(&db2, &phone);
}

#[tokio::test]
async fn dropped_connections_are_resumed_and_resent() {
    let (_dir, db) = temp_db();
    let receiver = start(&db, 64).await;
    let phone = PhoneSession::synthetic(3.0, 100.0);
    let options = ClientOptions {
        faults: Faults {
            disconnect_after: vec![2, 10, 11, 25],
            ..Faults::default()
        },
        ..fast()
    };
    let report = client::run(receiver.addr, &phone, &options).await.unwrap();
    assert_eq!(report.connections, 5);
    // Every reconnect resumed from what the receiver had stored.
    assert!(report.resumed_after[1..].iter().all(Option::is_some));
    receiver.stop().await;
    assert_complete(&db, &phone);
    let conn = read(&db);
    assert_eq!(mac_events(&conn, "reconnected"), 4);
    assert_eq!(mac_events(&conn, "connection_lost"), 4);
}

#[tokio::test]
async fn a_corrupted_frame_closes_the_connection_and_the_batch_is_resent() {
    let (_dir, db) = temp_db();
    let receiver = start(&db, 64).await;
    let phone = PhoneSession::synthetic(2.0, 100.0);
    let options = ClientOptions {
        faults: Faults {
            corrupt: vec![5],
            ..Faults::default()
        },
        ..fast()
    };
    let report = client::run(receiver.addr, &phone, &options).await.unwrap();
    assert_eq!(report.connections, 2);
    assert!(
        report.receiver_errors.iter().any(|e| e.contains("CRC")),
        "{:?}",
        report.receiver_errors
    );
    receiver.stop().await;
    assert_complete(&db, &phone);
    assert_eq!(mac_events(&read(&db), "message_refused"), 1);
}

#[tokio::test]
async fn a_malformed_batch_is_refused_and_nothing_from_it_is_stored() {
    let (_dir, db) = temp_db();
    let receiver = start(&db, 64).await;
    let phone = PhoneSession::synthetic(2.0, 100.0);
    let options = ClientOptions {
        faults: Faults {
            invalid: vec![3],
            ..Faults::default()
        },
        ..fast()
    };
    let report = client::run(receiver.addr, &phone, &options).await.unwrap();
    assert_eq!(report.connections, 2);
    assert!(
        report
            .receiver_errors
            .iter()
            .any(|e| e.contains("last_seq")),
        "{:?}",
        report.receiver_errors
    );
    receiver.stop().await;
    assert_complete(&db, &phone);
}

#[tokio::test]
async fn a_receiver_restart_mid_session_resumes_from_the_database() {
    let (_dir, db) = temp_db();
    let phone = PhoneSession::synthetic(3.0, 100.0);

    // First run: the phone sends part of the session, then the Mac stops.
    let first = start(&db, 64).await;
    let mut partial = phone.clone();
    partial.items.truncate(12);
    partial.bye = None;
    let acknowledged = send_without_bye(first.addr, &partial).await;
    let marked = first.stop().await;
    assert_eq!(marked, vec![phone.hello.session_id.clone()]);
    assert_eq!(sessions::list(&read(&db)).unwrap()[0].status, "incomplete");

    // Second run, new clock domain: the phone reconnects and finishes.
    let second = start(&db, 64).await;
    let report = client::run(second.addr, &phone, &fast()).await.unwrap();
    assert_eq!(report.resumed_after, vec![Some(acknowledged)]);
    second.stop().await;
    assert_complete(&db, &phone);
    let conn = read(&db);
    let domain_changed: i64 = conn
        .query_row(
            "SELECT COUNT(*) FROM session_events
             WHERE kind = 'receiver_attached' AND severity = 'warning'",
            [],
            |r| r.get(0),
        )
        .unwrap();
    assert_eq!(domain_changed, 1);
}

/// Sends hello and every item, waits for the last batch to be acknowledged,
/// and returns that seq, without sending bye.
async fn send_without_bye(addr: SocketAddr, phone: &PhoneSession) -> u64 {
    let mut peer = Peer::connect(addr).await;
    peer.send(&Message::Hello(phone.hello.clone())).await;
    assert!(matches!(peer.recv().await, Message::HelloAck(a) if a.accepted));
    for item in &phone.items {
        peer.send(item).await;
    }
    let last = phone.last_seq().unwrap();
    loop {
        if let Message::BatchAck(ack) = peer.recv().await
            && ack.highest_contiguous_seq == last
        {
            return last;
        }
    }
}

#[tokio::test]
async fn a_second_phone_cannot_join_a_session() {
    let (_dir, db) = temp_db();
    let receiver = start(&db, 64).await;
    let phone = PhoneSession::synthetic(0.5, 100.0);
    client::run(receiver.addr, &phone, &fast()).await.unwrap();
    let mut impostor = phone.clone();
    impostor.hello.device.device_id = "99999999-9999-4999-8999-999999999999".into();
    let result = client::run(receiver.addr, &impostor, &fast()).await;
    assert!(
        matches!(&result, Err(ClientError::Rejected(r)) if r.contains("DeviceMismatch")),
        "{result:?}"
    );
    receiver.stop().await;
}

#[tokio::test]
async fn protocol_errors_get_an_error_message_and_a_closed_connection() {
    let (_dir, db) = temp_db();
    let receiver = start(&db, 64).await;
    let phone = PhoneSession::synthetic(0.2, 100.0);

    let hello = serde_json::to_value(Message::Hello(phone.hello.clone())).unwrap();

    // A batch before hello.
    let mut peer = Peer::connect(receiver.addr).await;
    peer.send(&phone.items[1]).await;
    peer.expect_error(ErrorCode::UnknownSession).await;

    // A future protocol version.
    let mut peer = Peer::connect(receiver.addr).await;
    let mut future = hello.clone();
    future["protocol_version"] = json!(PROTOCOL_VERSION + 1);
    peer.send_json(&future).await;
    peer.expect_error(ErrorCode::UnsupportedVersion).await;

    // A schema violation: an unexpected field.
    let mut peer = Peer::connect(receiver.addr).await;
    let mut extra = hello.clone();
    extra["unexpected_field"] = json!("x");
    peer.send_json(&extra).await;
    peer.expect_error(ErrorCode::InvalidMessage).await;

    receiver.stop().await;
    assert!(sessions::list(&read(&db)).unwrap().is_empty());
}

#[tokio::test]
async fn a_tiny_writer_queue_applies_backpressure_without_losing_data() {
    let (_dir, db) = temp_db();
    let receiver = start(&db, 1).await;
    let phone = PhoneSession::synthetic(3.0, 200.0);
    client::run(receiver.addr, &phone, &fast()).await.unwrap();
    receiver.stop().await;
    assert_complete(&db, &phone);
}

/// A raw connection to the receiver, for messages the client would never send.
struct Peer {
    stream: TcpStream,
    decoder: Decoder,
}

impl Peer {
    async fn connect(addr: SocketAddr) -> Self {
        Self {
            stream: TcpStream::connect(addr).await.unwrap(),
            decoder: Decoder::new(),
        }
    }

    async fn send(&mut self, message: &Message) {
        self.send_json(&serde_json::to_value(message).unwrap())
            .await;
    }

    async fn send_json(&mut self, value: &serde_json::Value) {
        let frame = framing::encode_payload(&serde_json::to_vec(value).unwrap()).unwrap();
        self.stream.write_all(&frame).await.unwrap();
    }

    async fn recv(&mut self) -> Message {
        let mut buf = [0u8; 4096];
        loop {
            if let Some(m) = self.decoder.next_message().unwrap() {
                return m;
            }
            let n = timeout(Duration::from_secs(5), self.stream.read(&mut buf))
                .await
                .expect("receiver replied in time")
                .unwrap();
            assert!(n > 0, "connection closed before a reply");
            self.decoder.push(&buf[..n]);
        }
    }

    async fn expect_error(mut self, code: ErrorCode) {
        match self.recv().await {
            Message::Error(e) => assert_eq!(e.code, code, "{}", e.message),
            other => panic!("expected an error, got {other:?}"),
        }
        let mut rest = Vec::new();
        timeout(Duration::from_secs(5), self.stream.read_to_end(&mut rest))
            .await
            .expect("receiver closed the connection")
            .unwrap();
    }
}
