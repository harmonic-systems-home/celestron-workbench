//! `cwb`: Celestron Workbench command-line tools.
//!
//! Report commands arrive in later milestones. Nothing here can move a mount.

use std::{
    fs::{self, File},
    io::{BufReader, BufWriter},
    net::{IpAddr, Ipv6Addr, SocketAddr},
    path::{Path, PathBuf},
    process::ExitCode,
    sync::{Arc, atomic::Ordering},
};

use anyhow::{Context, Result};
use clap::{Args, Parser, Subcommand};
use cwb_receiver::{
    DEFAULT_PORT, Server,
    advertise::Advertisement,
    client::{self, ClientOptions, ClockSim, PhoneSession},
    writer,
};
use cwb_storage::{
    Connection, MacClock, Store, StoreConfig,
    clockfit::{self, ClockModel},
    sessions,
};
use serde_json::{Value, json};

#[derive(Parser)]
#[command(name = "cwb", version, about)]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Args)]
struct Db {
    /// Path to the SQLite database (keep it outside this repo).
    #[arg(long, env = "CWB_DB")]
    db: PathBuf,
}

#[derive(Subcommand)]
enum Command {
    /// Create the database if needed and apply pending migrations.
    Migrate {
        #[command(flatten)]
        db: Db,
    },
    /// Validate protocol messages against the v1 schema.
    /// Accepts .json files (one message) and .ndjson files (one per line).
    Validate {
        #[arg(required = true)]
        files: Vec<PathBuf>,
    },
    /// Receive sessions from the IMU Logger and store them. Runs until Ctrl-C.
    Receive {
        #[command(flatten)]
        db: Db,
        /// TCP port to listen on.
        #[arg(long, default_value_t = DEFAULT_PORT)]
        port: u16,
        /// Address to listen on. The default accepts IPv4 and IPv6 on all interfaces.
        #[arg(long, default_value_t = IpAddr::V6(Ipv6Addr::UNSPECIFIED))]
        bind: IpAddr,
        /// Name shown in the phone's receiver list.
        #[arg(long, default_value = "Celestron Workbench")]
        name: String,
        /// Don't advertise the receiver with Bonjour.
        #[arg(long)]
        no_advertise: bool,
        /// Requests the database writer may queue before senders wait.
        #[arg(long, default_value_t = 256)]
        queue: usize,
    },
    /// Inspect and manage stored sessions.
    Session {
        #[command(subcommand)]
        command: SessionCommand,
    },
    /// Send a session log (or a synthetic session) to a receiver, acting as
    /// the phone. Useful without a phone, and for exercising the receiver.
    Replay {
        /// Session log (.ndjson) from the phone or `cwb session export`.
        #[arg(required_unless_present = "synthetic", conflicts_with = "synthetic")]
        file: Option<PathBuf>,
        /// Generate a synthetic session of this many seconds instead.
        #[arg(long, value_name = "SECONDS")]
        synthetic: Option<f64>,
        /// Sample rate of the synthetic session.
        #[arg(long, default_value_t = 100.0, requires = "synthetic")]
        rate: f64,
        /// Receiver address, e.g. 127.0.0.1:47800.
        #[arg(long, default_value_t = SocketAddr::from(([127, 0, 0, 1], DEFAULT_PORT)))]
        to: SocketAddr,
        /// Replay speed relative to the recording; 0 sends as fast as possible.
        #[arg(long, default_value_t = 1.0)]
        speed: f64,
        /// Run a clock exchange this often while sending (synthetic sessions
        /// only: a recorded log's phone clock can't be reproduced).
        #[arg(long, value_name = "SECONDS", requires = "synthetic")]
        clock_interval: Option<f64>,
    },
    /// Print the software, protocol and database schema versions.
    Versions,
}

#[derive(Subcommand)]
enum SessionCommand {
    /// List stored sessions.
    List {
        #[command(flatten)]
        db: Db,
    },
    /// Check a stored session: sequence coverage, timestamps, bye, ingest
    /// events. Exits non-zero if anything is missing or suspect.
    Validate {
        #[command(flatten)]
        db: Db,
        /// Session ID or a unique prefix of it.
        session: String,
        /// Print the full report as JSON.
        #[arg(long)]
        json: bool,
    },
    /// Fit phone-to-Mac clock models from the session's clock exchanges, one
    /// per device and receiver run, and print them.
    Clock {
        #[command(flatten)]
        db: Db,
        session: String,
        /// Store the models in the database (earlier models are kept).
        #[arg(long)]
        save: bool,
        /// Print the models as JSON.
        #[arg(long)]
        json: bool,
    },
    /// Close a session whose phone never sent `bye`, marking it incomplete.
    Stop {
        #[command(flatten)]
        db: Db,
        session: String,
    },
    /// Export a session as protocol NDJSON (replayable and importable).
    Export {
        #[command(flatten)]
        db: Db,
        session: String,
        /// Output file; must not exist yet.
        #[arg(long, short)]
        out: PathBuf,
    },
    /// Create or complete a session from a phone session log. Samples already
    /// stored are skipped, so this fills in whatever the network missed.
    Import {
        #[command(flatten)]
        db: Db,
        file: PathBuf,
    },
}

fn main() -> Result<ExitCode> {
    match Cli::parse().command {
        Command::Migrate { db } => {
            let (_, applied) = open(&db.db)?;
            if applied.is_empty() {
                println!(
                    "{}: already at schema version {}",
                    db.db.display(),
                    cwb_storage::SCHEMA_VERSION
                );
            } else {
                println!("{}: applied migrations {applied:?}", db.db.display());
            }
            Ok(ExitCode::SUCCESS)
        }
        Command::Validate { files } => validate(&files),
        Command::Receive {
            db,
            port,
            bind,
            name,
            no_advertise,
            queue,
        } => {
            init_logging();
            runtime()?.block_on(receive(
                &db.db,
                SocketAddr::new(bind, port),
                &name,
                !no_advertise,
                queue,
            ))
        }
        Command::Session { command } => session(command),
        Command::Replay {
            file,
            synthetic,
            rate,
            to,
            speed,
            clock_interval,
        } => {
            init_logging();
            let session = match (file, synthetic) {
                (Some(file), _) => PhoneSession::from_log(&mut BufReader::new(
                    File::open(&file).with_context(|| format!("opening {}", file.display()))?,
                ))?,
                (None, Some(seconds)) => PhoneSession::synthetic(seconds, rate),
                (None, None) => unreachable!("clap requires one"),
            };
            let options = ClientOptions {
                speed: (speed > 0.0).then_some(speed),
                clock: clock_interval.map(|seconds| ClockSim {
                    interval: std::time::Duration::from_secs_f64(seconds),
                    epoch: std::time::Instant::now(),
                    epoch_phone_ns: session.batches().next().map_or(0, |b| b.samples[0].t_ns()),
                    drift_ppm: 0.0,
                    outbound_delay: std::time::Duration::ZERO,
                }),
                ..ClientOptions::default()
            };
            println!(
                "replaying session {} ({} batches) to {to}",
                session.hello.session_id,
                session.batches().count()
            );
            let report = runtime()?.block_on(client::run(to, &session, &options))?;
            println!(
                "done: {} batches sent, {} resent, {} connection(s), acknowledged to seq {:?}, {} clock exchanges",
                report.batches_sent,
                report.batches_resent,
                report.connections,
                report.acknowledged,
                report.clock_results
            );
            Ok(ExitCode::SUCCESS)
        }
        Command::Versions => {
            println!("cwb {}", env!("CARGO_PKG_VERSION"));
            println!("protocol {}", cwb_protocol::PROTOCOL_VERSION);
            println!("database schema {}", cwb_storage::SCHEMA_VERSION);
            Ok(ExitCode::SUCCESS)
        }
    }
}

fn open(db: &Path) -> Result<(Connection, Vec<u32>)> {
    cwb_storage::open(db).with_context(|| format!("opening {}", db.display()))
}

fn store(db: &Path, clock: &MacClock) -> Result<Store> {
    let (conn, _) = open(db)?;
    Ok(Store::new(
        conn,
        StoreConfig {
            mac_clock_boot_id: clock.boot_id().to_owned(),
            software_versions: json!({
                "cwb": env!("CARGO_PKG_VERSION"),
                "protocol": cwb_protocol::PROTOCOL_VERSION,
            }),
        },
    ))
}

fn runtime() -> Result<tokio::runtime::Runtime> {
    Ok(tokio::runtime::Builder::new_multi_thread()
        .enable_all()
        .build()?)
}

fn init_logging() {
    use tracing_subscriber::EnvFilter;
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new("info")),
        )
        .with_writer(std::io::stderr)
        .with_ansi(std::io::IsTerminal::is_terminal(&std::io::stderr()))
        .init();
}

async fn receive(
    db: &Path,
    addr: SocketAddr,
    name: &str,
    advertise: bool,
    queue: usize,
) -> Result<ExitCode> {
    let clock = Arc::new(MacClock::new());
    let store = store(db, &clock)?;
    let (writer, thread) = writer::spawn(store, queue);
    let server = Server::bind(addr, writer.clone(), clock)
        .await
        .with_context(|| format!("listening on port {}", addr.port()))?;
    let port = server.local_addr()?.port();
    let _advertisement = if advertise {
        match Advertisement::start(name, port) {
            Ok(a) => Some(a),
            Err(e) => {
                tracing::warn!(
                    "Bonjour advertisement failed ({e}); enter the address on the phone"
                );
                None
            }
        }
    } else {
        None
    };
    tracing::info!(
        port,
        database = %db.display(),
        "receiving{}; Ctrl-C to stop",
        if advertise { format!(" as \"{name}\"") } else { String::new() }
    );
    server
        .run(async {
            let _ = tokio::signal::ctrl_c().await;
        })
        .await;
    let marked = writer
        .shutdown("receiver stopped before bye")
        .await
        .context("stopping the database writer")?;
    for session in &marked {
        tracing::warn!(
            session,
            "marked incomplete: no bye before the receiver stopped"
        );
    }
    let stats = writer.stats();
    tracing::info!(
        requests = stats.requests.load(Ordering::Relaxed),
        backpressure_waits = stats.backpressure_waits.load(Ordering::Relaxed),
        "stopped"
    );
    drop(writer);
    tokio::task::spawn_blocking(move || thread.join())
        .await?
        .map_err(|_| anyhow::anyhow!("database writer panicked"))?;
    Ok(ExitCode::SUCCESS)
}

fn session(command: SessionCommand) -> Result<ExitCode> {
    match command {
        SessionCommand::List { db } => {
            let (conn, _) = open(&db.db)?;
            let list = sessions::list(&conn)?;
            if list.is_empty() {
                println!("no sessions");
            }
            for s in list {
                println!(
                    "{}  {}  {:<10}  {:>9} samples  {:>3} markers{}",
                    s.session_id,
                    s.created_utc,
                    s.status,
                    s.samples,
                    s.markers,
                    s.status_reason
                        .map(|r| format!("  ({r})"))
                        .unwrap_or_default()
                );
            }
            Ok(ExitCode::SUCCESS)
        }
        SessionCommand::Validate { db, session, json } => {
            let (conn, _) = open(&db.db)?;
            let id = sessions::resolve(&conn, &session)?;
            let report = sessions::validate(&conn, &id)?;
            if json {
                println!("{}", serde_json::to_string_pretty(&report)?);
            } else {
                print_report(&report);
            }
            Ok(if report.problems.is_empty() {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            })
        }
        SessionCommand::Clock {
            db,
            session,
            save,
            json,
        } => {
            let (conn, _) = open(&db.db)?;
            let id = sessions::resolve(&conn, &session)?;
            let models = clockfit::fit_session(&conn, &id)?;
            let ids = if save {
                clockfit::store(&conn, &id, &models)?
            } else {
                Vec::new()
            };
            if json {
                let out: Vec<Value> = models
                    .iter()
                    .enumerate()
                    .map(|(i, (device_id, model))| {
                        json!({
                            "device_id": device_id,
                            "clock_model_id": ids.get(i),
                            "model": model,
                        })
                    })
                    .collect();
                println!("{}", serde_json::to_string_pretty(&out)?);
            } else {
                println!("session {id}");
                if models.is_empty() {
                    println!("  no clock exchanges");
                }
                for (i, (device_id, model)) in models.iter().enumerate() {
                    print_clock(device_id, model);
                    if let Some(model_id) = ids.get(i) {
                        println!("    saved as clock model {model_id}");
                    }
                }
            }
            Ok(ExitCode::SUCCESS)
        }
        SessionCommand::Stop { db, session } => {
            let clock = MacClock::new();
            let mut store = store(&db.db, &clock)?;
            let id = sessions::resolve(store.connection(), &session)?;
            if store.mark_incomplete(&id, "closed from the Mac before bye")? {
                println!("{id}: marked incomplete");
            } else {
                println!("{id}: not recording; unchanged");
            }
            Ok(ExitCode::SUCCESS)
        }
        SessionCommand::Export { db, session, out } => {
            let (conn, _) = open(&db.db)?;
            let id = sessions::resolve(&conn, &session)?;
            let file = File::options()
                .write(true)
                .create_new(true)
                .open(&out)
                .with_context(|| format!("creating {}", out.display()))?;
            let summary = sessions::export(&conn, &id, &mut BufWriter::new(file))?;
            println!(
                "{}: {} messages, {} samples\nsha256 {}",
                out.display(),
                summary.messages,
                summary.samples,
                summary.sha256
            );
            Ok(ExitCode::SUCCESS)
        }
        SessionCommand::Import { db, file } => {
            let clock = MacClock::new();
            let mut store = store(&db.db, &clock)?;
            let mut input = BufReader::new(
                File::open(&file).with_context(|| format!("opening {}", file.display()))?,
            );
            let summary = sessions::import(&mut store, &mut input, &|| clock.now_ns())?;
            store.checkpoint()?;
            println!(
                "session {} ({}): {} samples stored, {} already present, {} conflicting, {} markers, {} events, {} clock exchanges",
                summary.session_id.as_deref().unwrap_or("?"),
                if summary.created { "new" } else { "existing" },
                summary.stored_samples,
                summary.duplicate_samples,
                summary.conflicting_samples,
                summary.markers,
                summary.events,
                summary.clock_exchanges
            );
            for skipped in &summary.skipped {
                println!("  skipped {skipped}");
            }
            println!("sha256 {}", summary.sha256);
            Ok(if summary.conflicting_samples == 0 {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            })
        }
    }
}

fn print_report(report: &sessions::SessionReport) {
    let s = &report.session;
    println!("session {}", s.session_id);
    println!(
        "  status {}{}",
        s.status,
        s.status_reason
            .as_ref()
            .map(|r| format!(" ({r})"))
            .unwrap_or_default()
    );
    println!(
        "  created {}  ended {}",
        s.created_utc,
        s.ended_utc.as_deref().unwrap_or("-")
    );
    println!("  {} samples, {} markers", s.samples, s.markers);
    for d in &report.devices {
        println!("  device {}", d.device_id);
        println!(
            "    seq {:?}..={:?}, {} missing range(s), dropped on phone {}",
            d.first_seq,
            d.last_seq,
            d.missing.len(),
            d.dropped_on_phone
        );
        for st in &d.streams {
            println!(
                "    {:<14} {:>8} samples  {:>8}  interval {}..{}",
                st.stream,
                st.samples,
                st.rate_hz.map_or("-".into(), |r| format!("{r:.2} Hz")),
                st.min_interval_ns
                    .map_or("-".into(), |n| format!("{:.3}", n as f64 / 1e6)),
                st.max_interval_ns
                    .map_or("-".into(), |n| format!("{:.3} ms", n as f64 / 1e6)),
            );
        }
    }
    println!("  events:");
    for (kind, count) in &report.events {
        println!("    {kind:<32} {count}");
    }
    if report.clock.is_empty() {
        println!("  clock: no exchanges");
    }
    for (device_id, model) in &report.clock {
        print_clock(device_id, model);
    }
    if report.problems.is_empty() {
        println!("OK: no problems found");
    } else {
        println!("PROBLEMS:");
        for p in &report.problems {
            println!("  - {p}");
        }
    }
}

fn print_clock(device_id: &str, model: &ClockModel) {
    let ms = |ns: f64| format!("{:.3} ms", ns / 1e6);
    println!(
        "  clock: device {} receiver run {}",
        &device_id[..8.min(device_id.len())],
        &model.mac_clock_boot_id[..8.min(model.mac_clock_boot_id.len())]
    );
    println!(
        "    {} exchanges over {:.1} s, {} used; round trip min {}, median {}",
        model.exchanges,
        (model.valid_to_phone_ns - model.valid_from_phone_ns) as f64 / 1e9,
        model.used,
        ms(model.round_trip_min_ns as f64),
        ms(model.round_trip_median_ns as f64)
    );
    println!(
        "    offset {} s, drift {}, uncertainty ±{} (residual rms {})",
        format_args!("{:+.6}", model.offset_ns as f64 / 1e9),
        if model.drift_fitted {
            format!("{:+.2} ppm", model.drift_ppb / 1e3)
        } else {
            "not fitted (needs 30 s and 3 exchanges)".into()
        },
        ms(model.uncertainty_ns as f64),
        ms(model.residual_rms_ns)
    );
}

fn validate(files: &[PathBuf]) -> Result<ExitCode> {
    let mut failures = 0usize;
    let mut checked = 0usize;
    for path in files {
        let text =
            fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;
        let ndjson = path.extension().is_some_and(|e| e == "ndjson");
        let documents: Vec<(usize, &str)> = if ndjson {
            text.lines()
                .enumerate()
                .filter(|(_, l)| !l.trim().is_empty())
                .map(|(i, l)| (i + 1, l))
                .collect()
        } else {
            vec![(1, text.as_str())]
        };
        for (line, doc) in documents {
            checked += 1;
            let location = if ndjson {
                format!("{}:{line}", path.display())
            } else {
                path.display().to_string()
            };
            let errors = match serde_json::from_str::<Value>(doc) {
                Err(e) => vec![format!("not JSON: {e}")],
                Ok(value) => check_message(&value),
            };
            for error in &errors {
                eprintln!("{location}: {error}");
            }
            if !errors.is_empty() {
                failures += 1;
            }
        }
    }
    println!("{checked} message(s) checked, {failures} invalid");
    Ok(if failures == 0 {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    })
}

fn check_message(value: &Value) -> Vec<String> {
    if let Err(errors) = cwb_protocol::schema::validate(value) {
        return errors;
    }
    match serde_json::from_value::<cwb_protocol::Message>(value.clone()) {
        Err(e) => vec![format!("schema-valid but not decodable: {e}")],
        Ok(cwb_protocol::Message::SampleBatch(batch)) => {
            batch.check_contiguous().err().into_iter().collect()
        }
        Ok(_) => Vec::new(),
    }
}
