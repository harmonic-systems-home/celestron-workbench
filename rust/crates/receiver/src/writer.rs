//! The single database writer (ADR 0003).
//!
//! One OS thread owns the [`Store`]. Connection tasks send it requests over a
//! bounded channel and wait for the reply before acknowledging anything, so an
//! acknowledgement always means the data is committed. When the channel is
//! full, senders wait: the back-pressure reaches the phone through TCP, and
//! each wait is counted.

use std::{
    collections::HashSet,
    sync::{
        Arc,
        atomic::{AtomicU64, Ordering},
    },
    thread,
};

use cwb_protocol::{Bye, ClockResult, Event, Hello, Marker, Nanos, SampleBatch, Site};
use cwb_storage::{BatchOutcome, ByeOutcome, HelloOutcome, StorageError, Store};
use thiserror::Error;
use tokio::sync::{mpsc, oneshot};

#[derive(Debug, Error)]
pub enum WriterError {
    #[error(transparent)]
    Storage(#[from] StorageError),
    #[error("the database writer has stopped")]
    Stopped,
}

/// Counters shared with the connection tasks.
#[derive(Debug, Default)]
pub struct WriterStats {
    /// Times a sender found the channel full and had to wait.
    pub backpressure_waits: AtomicU64,
    pub requests: AtomicU64,
}

type Reply<T> = oneshot::Sender<Result<T, StorageError>>;

enum Request {
    Hello(Hello, Nanos, Reply<HelloOutcome>),
    Batch(SampleBatch, Nanos, Reply<BatchOutcome>),
    Marker(Marker, Reply<bool>),
    Event(Event, Nanos, Reply<bool>),
    Site(Site, Nanos, Reply<bool>),
    ClockResult(ClockResult, Reply<bool>),
    Bye(Bye, Nanos, Reply<ByeOutcome>),
    MacEvent {
        session_id: String,
        device_id: Option<String>,
        kind: &'static str,
        severity: &'static str,
        detail: serde_json::Value,
        receive_mac_ns: Nanos,
    },
    Shutdown(String, oneshot::Sender<Vec<String>>),
}

#[derive(Clone)]
pub struct WriterHandle {
    tx: mpsc::Sender<Request>,
    stats: Arc<WriterStats>,
}

/// Starts the writer thread. It runs until [`WriterHandle::shutdown`] is
/// called or every handle is dropped, and then returns the store.
pub fn spawn(store: Store, capacity: usize) -> (WriterHandle, thread::JoinHandle<Store>) {
    let (tx, rx) = mpsc::channel(capacity);
    let stats = Arc::new(WriterStats::default());
    let thread = thread::Builder::new()
        .name("cwb-db-writer".into())
        .spawn(move || run(store, rx))
        .expect("spawn the database writer thread");
    (WriterHandle { tx, stats }, thread)
}

fn run(mut store: Store, mut rx: mpsc::Receiver<Request>) -> Store {
    let mut sessions: HashSet<String> = HashSet::new();
    while let Some(request) = rx.blocking_recv() {
        match request {
            Request::Hello(hello, ns, reply) => {
                let result = store.hello(&hello, ns);
                if let Ok(HelloOutcome::Accepted { .. }) = &result {
                    sessions.insert(hello.session_id.clone());
                }
                let _ = reply.send(result);
            }
            Request::Batch(batch, ns, reply) => {
                let _ = reply.send(store.batch(&batch, ns));
            }
            Request::Marker(marker, reply) => {
                let _ = reply.send(store.marker(&marker));
            }
            Request::Event(event, ns, reply) => {
                let _ = reply.send(store.phone_event(&event, ns));
            }
            Request::Site(site, ns, reply) => {
                let _ = reply.send(store.site(&site, ns));
            }
            Request::ClockResult(result, reply) => {
                let _ = reply.send(store.clock_result(&result));
            }
            Request::Bye(bye, ns, reply) => {
                let result = store.bye(&bye, ns);
                if result.is_ok() {
                    sessions.remove(&bye.session_id);
                }
                let _ = reply.send(result);
            }
            Request::MacEvent {
                session_id,
                device_id,
                kind,
                severity,
                detail,
                receive_mac_ns,
            } => {
                if let Err(e) = store.mac_event(
                    &session_id,
                    device_id.as_deref(),
                    kind,
                    severity,
                    detail,
                    receive_mac_ns,
                ) {
                    tracing::error!(%session_id, kind, "could not record event: {e}");
                }
            }
            Request::Shutdown(reason, reply) => {
                let _ = reply.send(finish(&mut store, &sessions, &reason));
                return store;
            }
        }
    }
    finish(&mut store, &sessions, "receiver stopped before bye");
    store
}

/// Marks sessions still recording as incomplete and checkpoints the WAL.
fn finish(store: &mut Store, sessions: &HashSet<String>, reason: &str) -> Vec<String> {
    let mut marked = Vec::new();
    for session in sessions {
        match store.mark_incomplete(session, reason) {
            Ok(true) => marked.push(session.clone()),
            Ok(false) => {}
            Err(e) => tracing::error!(%session, "could not mark session incomplete: {e}"),
        }
    }
    if let Err(e) = store.checkpoint() {
        tracing::warn!("WAL checkpoint failed: {e}");
    }
    marked.sort();
    marked
}

impl WriterHandle {
    pub fn stats(&self) -> &WriterStats {
        &self.stats
    }

    pub async fn hello(&self, hello: Hello, ns: Nanos) -> Result<HelloOutcome, WriterError> {
        self.call(|reply| Request::Hello(hello, ns, reply)).await
    }

    pub async fn batch(&self, batch: SampleBatch, ns: Nanos) -> Result<BatchOutcome, WriterError> {
        self.call(|reply| Request::Batch(batch, ns, reply)).await
    }

    pub async fn marker(&self, marker: Marker) -> Result<bool, WriterError> {
        self.call(|reply| Request::Marker(marker, reply)).await
    }

    pub async fn event(&self, event: Event, ns: Nanos) -> Result<bool, WriterError> {
        self.call(|reply| Request::Event(event, ns, reply)).await
    }

    pub async fn site(&self, site: Site, ns: Nanos) -> Result<bool, WriterError> {
        self.call(|reply| Request::Site(site, ns, reply)).await
    }

    pub async fn clock_result(&self, result: ClockResult) -> Result<bool, WriterError> {
        self.call(|reply| Request::ClockResult(result, reply)).await
    }

    pub async fn bye(&self, bye: Bye, ns: Nanos) -> Result<ByeOutcome, WriterError> {
        self.call(|reply| Request::Bye(bye, ns, reply)).await
    }

    /// Records a Mac-side event without waiting for it to be written.
    pub async fn mac_event(
        &self,
        session_id: &str,
        device_id: Option<&str>,
        kind: &'static str,
        severity: &'static str,
        detail: serde_json::Value,
        receive_mac_ns: Nanos,
    ) {
        let request = Request::MacEvent {
            session_id: session_id.to_owned(),
            device_id: device_id.map(str::to_owned),
            kind,
            severity,
            detail,
            receive_mac_ns,
        };
        let _ = self.send(request).await;
    }

    /// Marks sessions this run accepted, and that have not ended, as
    /// incomplete; checkpoints; and stops the writer. Returns those sessions.
    pub async fn shutdown(&self, reason: &str) -> Result<Vec<String>, WriterError> {
        let (reply, rx) = oneshot::channel();
        self.send(Request::Shutdown(reason.to_owned(), reply))
            .await?;
        rx.await.map_err(|_| WriterError::Stopped)
    }

    async fn call<T>(&self, request: impl FnOnce(Reply<T>) -> Request) -> Result<T, WriterError> {
        let (reply, rx) = oneshot::channel();
        self.send(request(reply)).await?;
        Ok(rx.await.map_err(|_| WriterError::Stopped)??)
    }

    async fn send(&self, request: Request) -> Result<(), WriterError> {
        self.stats.requests.fetch_add(1, Ordering::Relaxed);
        match self.tx.try_send(request) {
            Ok(()) => Ok(()),
            Err(mpsc::error::TrySendError::Full(request)) => {
                self.stats
                    .backpressure_waits
                    .fetch_add(1, Ordering::Relaxed);
                tracing::debug!("database writer queue is full; waiting");
                self.tx
                    .send(request)
                    .await
                    .map_err(|_| WriterError::Stopped)
            }
            Err(mpsc::error::TrySendError::Closed(_)) => Err(WriterError::Stopped),
        }
    }
}
