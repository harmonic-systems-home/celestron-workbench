//! `cwb`: Celestron Workbench command-line tools.
//!
//! Only `cwb mount run` can move a mount (plan Prompt 8, ADR 0013): `cwb
//! celestron` sends read-only queries, plus the hand controller's time and
//! location with `setup`.

mod mount;

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
    /// Analyse a stored session (plan Prompt 5): timing, still windows, noise
    /// and drift, resolution versus window length, moves. Writes a report
    /// folder (Markdown, HTML, JSON, CSV, SVG).
    Analyze {
        #[command(flatten)]
        db: Db,
        /// Session ID or a unique prefix of it.
        session: String,
        /// Analysis config (TOML). Defaults to the committed analysis/stationary.toml.
        #[arg(long)]
        config: Option<PathBuf>,
        /// Output folder. Defaults to reports/<session prefix>/ (git-ignored).
        #[arg(long, short)]
        out: Option<PathBuf>,
        /// Device ID prefix, for sessions with more than one device.
        #[arg(long)]
        device: Option<String>,
    },
    /// Celestron hand controller tools: read-only discovery (plan Prompt 7)
    /// and setting its time and location. Nothing here moves the mount.
    Celestron {
        #[command(subcommand)]
        command: CelestronCommand,
    },
    /// The interactive mount test runner (plan Prompt 8). Starts disarmed;
    /// moves one axis at a time, slowly and briefly, under the interlocks.
    Mount {
        #[command(subcommand)]
        command: MountCmd,
    },
    /// Print the software, protocol and database schema versions.
    Versions,
}

#[derive(Subcommand)]
enum CelestronCommand {
    /// List serial ports, USB ones first. Sends nothing.
    Ports,
    /// Print every byte sequence `discover` would send, with its reference. Sends nothing.
    Queries {
        #[arg(long, default_value_t = 20)]
        repeats: usize,
    },
    /// Query the hand controller and write a compatibility report folder
    /// (report.md, report.json, trace.ndjson).
    Discover {
        /// Serial device, e.g. /dev/cu.usbserial-… (see `cwb celestron ports`).
        #[arg(long, required_unless_present = "simulate")]
        port: Option<String>,
        /// Use the built-in simulated hand controller instead of hardware.
        #[arg(long, conflicts_with = "port")]
        simulate: bool,
        /// Position-and-echo pairs to time after identification.
        #[arg(long, default_value_t = 20)]
        repeats: usize,
        /// Parent folder; the report goes in a timestamped folder inside.
        #[arg(long, short, default_value = "reports/discovery")]
        out: PathBuf,
        /// Mount, as you know it (the protocol reports only a model code).
        #[arg(long)]
        mount: Option<String>,
        /// Hand controller, e.g. "NexStar+".
        #[arg(long)]
        hand_controller: Option<String>,
        /// Hand controller firmware as its display shows it.
        #[arg(long)]
        hand_controller_firmware: Option<String>,
        /// Cable or adapter used.
        #[arg(long)]
        cable: Option<String>,
        #[arg(long)]
        notes: Option<String>,
    },
    /// The stop-form test (docs/observations.md, O1): confirm the mount is
    /// still, send ONE rate-0 stop command to one axis, and watch the mount's
    /// own positions for creep. Only rate-0 commands can be sent.
    StopTest {
        /// Serial device, e.g. /dev/cu.usbserial-… (see `cwb celestron ports`).
        #[arg(long, required_unless_present = "simulate")]
        port: Option<String>,
        /// Use the simulated hand controller and mount instead of hardware.
        #[arg(long, conflicts_with = "port")]
        simulate: bool,
        /// azm or alt.
        #[arg(long)]
        axis: String,
        /// variable+, variable-, fixed+ or fixed-.
        #[arg(long)]
        form: String,
        /// Seconds to watch before sending (the mount must be still).
        #[arg(long, default_value_t = 5.0)]
        before: f64,
        /// Seconds to watch after sending.
        #[arg(long, default_value_t = 30.0)]
        after: f64,
        /// Where the result goes (git-ignored).
        #[arg(long, short, default_value = "reports/stop-test")]
        out: PathBuf,
        /// Don't ask for confirmation.
        #[arg(long)]
        yes: bool,
    },
    /// Find a command that cancels a variable-rate creep (docs/observations.md,
    /// O1): start the creep with variable rate 0 if the axis is still, then
    /// try each candidate in turn until one leaves the mount still.
    CancelSweep {
        /// Serial device, e.g. /dev/cu.usbserial-… (see `cwb celestron ports`).
        #[arg(long, required_unless_present = "simulate")]
        port: Option<String>,
        /// Use the simulated hand controller and mount instead of hardware.
        #[arg(long, conflicts_with = "port")]
        simulate: bool,
        /// azm or alt.
        #[arg(long, default_value = "azm")]
        axis: String,
        /// Seconds to watch after each candidate.
        #[arg(long, default_value_t = 15.0)]
        watch: f64,
        #[arg(long, short, default_value = "reports/stop-test")]
        out: PathBuf,
        /// Don't ask for confirmation.
        #[arg(long)]
        yes: bool,
    },
    /// Read the motor controllers' anti-backlash settings, and optionally set
    /// them (0–99), reading each back. No motion.
    Backlash {
        /// Serial device, e.g. /dev/cu.usbserial-… (see `cwb celestron ports`).
        #[arg(long, required_unless_present = "simulate")]
        port: Option<String>,
        /// Use a simulated hand controller instead of hardware.
        #[arg(long, conflicts_with = "port")]
        simulate: bool,
        /// Set one value: azm+=N, azm-=N, alt+=N or alt-=N. Repeatable.
        #[arg(long, value_name = "SLOT=N")]
        set: Vec<String>,
        /// Set all four to this value.
        #[arg(long, value_name = "N", conflicts_with = "set")]
        set_all: Option<u8>,
        /// Don't ask for confirmation.
        #[arg(long)]
        yes: bool,
    },
    /// Set the hand controller's time (from this Mac's clock) and location
    /// (from the site file), then read each back to confirm. No motion.
    Setup {
        /// Serial device, e.g. /dev/cu.usbserial-… (see `cwb celestron ports`).
        #[arg(long, required_unless_present = "simulate")]
        port: Option<String>,
        /// Use a simulated hand controller instead of hardware.
        #[arg(long, conflicts_with = "port")]
        simulate: bool,
        /// Where the location comes from. `auto` uses the newest precise
        /// phone fix in the database if there is one, else the site file.
        #[arg(long, value_enum, default_value_t = LocationFrom::Auto)]
        location_from: LocationFrom,
        /// Database holding the phone's fixes (for `auto` and `phone`).
        #[arg(long, env = "CWB_DB")]
        db: Option<PathBuf>,
        /// Site file (git-ignored; template in config/site.example.toml).
        #[arg(long, env = "CWB_SITE", default_value = "config/site.local.toml")]
        site: PathBuf,
        /// Set only the time; no site file needed unless it names the time zone.
        #[arg(long, conflicts_with = "location_only")]
        time_only: bool,
        /// Set only the location.
        #[arg(long)]
        location_only: bool,
        /// Don't ask for confirmation.
        #[arg(long)]
        yes: bool,
    },
}

#[derive(Subcommand)]
enum MountCmd {
    /// Check the hand controller, receive the phone's data, and run moves
    /// the operator types. An empty line is always Stop.
    Run {
        /// Serial device, e.g. /dev/cu.usbserial-… (see `cwb celestron ports`).
        #[arg(long, required_unless_present = "simulate")]
        port: Option<String>,
        /// Simulated hand controller and mount, no phone: to rehearse.
        #[arg(long, conflicts_with_all = ["port", "db"])]
        simulate: bool,
        /// Runner and safety settings.
        #[arg(long, default_value = "config/mount.toml")]
        config: PathBuf,
        /// Path to the SQLite database for the phone's samples (keep it outside this repo).
        #[arg(long, env = "CWB_DB")]
        db: Option<PathBuf>,
        /// TCP port for the phone.
        #[arg(long, default_value_t = DEFAULT_PORT)]
        listen_port: u16,
        /// Bonjour service name the phone sees.
        #[arg(long, default_value = "Celestron Workbench")]
        name: String,
        #[arg(long)]
        no_advertise: bool,
        /// Parent folder for the run log; it goes in a timestamped folder inside.
        #[arg(long, short, default_value = "reports/mount")]
        out: PathBuf,
    },
}

#[derive(Clone, Copy, PartialEq, Eq, clap::ValueEnum)]
enum LocationFrom {
    Auto,
    Phone,
    SiteFile,
}

/// Phone fixes less accurate than this aren't used to set the hand controller.
const PHONE_FIX_MAX_ACCURACY_M: f64 = 100.0;

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
        Command::Analyze {
            db,
            session,
            config,
            out,
            device,
        } => analyze(&db.db, &session, config.as_deref(), out, device.as_deref()),
        Command::Celestron { command } => celestron(command),
        Command::Mount {
            command:
                MountCmd::Run {
                    port,
                    simulate,
                    config,
                    db,
                    listen_port,
                    name,
                    no_advertise,
                    out,
                },
        } => {
            init_logging_at("warn");
            mount::run(mount::Options {
                port,
                simulate,
                config,
                db,
                listen: SocketAddr::new(IpAddr::V6(Ipv6Addr::UNSPECIFIED), listen_port),
                name,
                advertise: !no_advertise,
                out,
            })
        }
        Command::Versions => {
            println!("cwb {}", env!("CARGO_PKG_VERSION"));
            println!("protocol {}", cwb_protocol::PROTOCOL_VERSION);
            println!("database schema {}", cwb_storage::SCHEMA_VERSION);
            Ok(ExitCode::SUCCESS)
        }
    }
}

fn celestron(command: CelestronCommand) -> Result<ExitCode> {
    use cwb_celestron_discovery::{
        HandController,
        discover::{Connection, OperatorInfo},
        fake::{FakeHandController, FakeSetup},
        list_ports, query, redact_path, report, summarize,
    };

    match command {
        CelestronCommand::Ports => {
            let ports = list_ports().context("listing serial ports")?;
            if ports.is_empty() {
                println!("no serial ports found");
            }
            for p in ports {
                match p.usb {
                    Some(u) => println!("{}  {}", p.path, u.describe()),
                    None => println!("{}", p.path),
                }
            }
            Ok(ExitCode::SUCCESS)
        }
        CelestronCommand::Queries { repeats } => {
            println!(
                "Sent in this order at {} baud, 8N1; each reply ends with '#'.",
                cwb_celestron_discovery::link::BAUD
            );
            for (i, q) in query::plan(repeats).into_iter().enumerate() {
                println!(
                    "{i:>3}  {:<26} {:<24}  since {}.{}  {}",
                    q.to_string(),
                    cwb_celestron_discovery::discover::hex(&q.bytes()),
                    q.since_version().0,
                    q.since_version().1,
                    q.reference()
                );
            }
            println!(
                "Reference: {}\n  {}",
                query::REFERENCE,
                query::REFERENCE_URL
            );
            Ok(ExitCode::SUCCESS)
        }
        CelestronCommand::Discover {
            port,
            simulate,
            repeats,
            out,
            mount,
            hand_controller,
            hand_controller_firmware,
            cable,
            notes,
        } => {
            let operator = OperatorInfo {
                mount,
                hand_controller,
                hand_controller_firmware,
                cable,
                notes,
            };
            let settings = format!("{} baud, 8N1", cwb_celestron_discovery::link::BAUD);
            let (exchanges, connection) = if simulate {
                let mut hc = HandController::new(FakeHandController::new(FakeSetup::default()));
                cwb_celestron_discovery::discover(&mut hc, repeats);
                let connection = Connection {
                    port: "simulated".into(),
                    usb: None,
                    settings,
                };
                (hc.into_parts().1, connection)
            } else {
                let path = port.expect("clap requires --port without --simulate");
                let usb = list_ports()
                    .ok()
                    .and_then(|ports| ports.into_iter().find(|p| p.path == path))
                    .and_then(|p| p.usb);
                let link = open_serial(&path);
                eprintln!("querying {path} (read-only)…");
                let mut hc = HandController::new(link);
                cwb_celestron_discovery::discover(&mut hc, repeats);
                let connection = Connection {
                    port: redact_path(&path),
                    usb,
                    settings,
                };
                (hc.into_parts().1, connection)
            };
            let generated = cwb_storage::clock::utc_now();
            let dir = out.join(generated.replace(':', "-"));
            let d = summarize(exchanges, simulate, generated, operator, connection);
            report::write(&d, &dir).with_context(|| format!("writing {}", dir.display()))?;
            for c in &d.checks {
                println!(
                    "{:<24} {:<5} {}",
                    c.name,
                    format!("{:?}", c.status).to_lowercase(),
                    c.detail
                );
            }
            println!("\nreport: {}", dir.join("report.md").display());
            Ok(if d.ready() {
                ExitCode::SUCCESS
            } else {
                ExitCode::FAILURE
            })
        }
        CelestronCommand::StopTest {
            port,
            simulate,
            axis,
            form,
            before,
            after,
            out,
            yes,
        } => {
            use cwb_mount_celestron::stoptest::StopForm;
            let axis = match axis.as_str() {
                "azm" | "az" | "azimuth" => cwb_mount_core::Axis::Azimuth,
                "alt" | "altitude" => cwb_mount_core::Axis::Altitude,
                other => anyhow::bail!("--axis {other}: use azm or alt"),
            };
            let form = StopForm::parse(&form).with_context(|| {
                format!("--form {form}: use variable+, variable-, fixed+ or fixed-")
            })?;
            let mac = Arc::new(MacClock::new());
            let clock: cwb_mount_celestron::adapter::Clock = {
                let mac = mac.clone();
                Arc::new(move || mac.now_ns())
            };
            let windows = (
                std::time::Duration::from_secs_f64(before.max(1.0)),
                std::time::Duration::from_secs_f64(after.max(1.0)),
            );
            if simulate {
                let mount = Arc::new(std::sync::Mutex::new(cwb_mount_sim::SimMount::new(
                    cwb_mount_sim::SimFaults::default(),
                    30.0,
                    1,
                )));
                let link = cwb_mount_celestron::fake::SimHandController::new(mount, clock.clone());
                stop_test(link, &clock, axis, form, windows, &out, yes)
            } else {
                let path = port.expect("clap requires --port without --simulate");
                stop_test(open_serial(&path), &clock, axis, form, windows, &out, yes)
            }
        }
        CelestronCommand::CancelSweep {
            port,
            simulate,
            axis,
            watch,
            out,
            yes,
        } => {
            let axis = match axis.as_str() {
                "azm" | "az" | "azimuth" => cwb_mount_core::Axis::Azimuth,
                "alt" | "altitude" => cwb_mount_core::Axis::Altitude,
                other => anyhow::bail!("--axis {other}: use azm or alt"),
            };
            let mac = Arc::new(MacClock::new());
            let clock: cwb_mount_celestron::adapter::Clock = {
                let mac = mac.clone();
                Arc::new(move || mac.now_ns())
            };
            let watch = std::time::Duration::from_secs_f64(watch.max(5.0));
            if simulate {
                let mount = Arc::new(std::sync::Mutex::new(cwb_mount_sim::SimMount::new(
                    cwb_mount_sim::SimFaults::default(),
                    30.0,
                    1,
                )));
                let link = cwb_mount_celestron::fake::SimHandController::new(mount, clock.clone());
                cancel_sweep(link, &clock, axis, watch, &out, yes)
            } else {
                let path = port.expect("clap requires --port without --simulate");
                cancel_sweep(open_serial(&path), &clock, axis, watch, &out, yes)
            }
        }
        CelestronCommand::Backlash {
            port,
            simulate,
            set,
            set_all,
            yes,
        } => {
            use cwb_celestron_setup::backlash::{MAX, Slot};
            let mut changes: Vec<(Slot, u8)> = Vec::new();
            if let Some(v) = set_all {
                changes.extend(Slot::ALL.iter().map(|s| (*s, v)));
            }
            for item in &set {
                let (slot, value) = item
                    .split_once('=')
                    .and_then(|(s, v)| Some((Slot::parse(s)?, v.parse::<u8>().ok()?)))
                    .with_context(|| {
                        format!("--set {item}: use azm+=N, azm-=N, alt+=N or alt-=N")
                    })?;
                changes.push((slot, value));
            }
            if let Some((slot, v)) = changes.iter().find(|(_, v)| *v > MAX) {
                anyhow::bail!("{slot}={v}: values are 0–{MAX}");
            }
            if simulate {
                let mut fake = cwb_celestron_setup::fake::FakeSetter::default();
                fake.backlash = [[50, 50], [50, 50]];
                backlash(fake, &changes, yes)
            } else {
                let path = port.expect("clap requires --port without --simulate");
                let link = open_serial(&path);
                backlash(link, &changes, yes)
            }
        }
        CelestronCommand::Setup {
            port,
            simulate,
            location_from,
            db,
            site,
            time_only,
            location_only,
            yes,
        } => {
            let plan = SetupPlan::load(
                &site,
                db.as_deref(),
                location_from,
                !location_only,
                !time_only,
            )?;
            if simulate {
                setup(cwb_celestron_setup::fake::FakeSetter::default(), &plan, yes)
            } else {
                let path = port.expect("clap requires --port without --simulate");
                let link = open_serial(&path);
                setup(link, &plan, yes)
            }
        }
    }
}

/// A still mount's own positions don't change at all: allow one unit
/// (0.077″) of reading noise on each axis.
const STILL_ARCSEC: f64 = 0.08;

fn stop_test(
    mut link: impl cwb_celestron_discovery::Link,
    clock: &cwb_mount_celestron::adapter::Clock,
    axis: cwb_mount_core::Axis,
    form: cwb_mount_celestron::stoptest::StopForm,
    (before, after): (std::time::Duration, std::time::Duration),
    out: &Path,
    yes: bool,
) -> Result<ExitCode> {
    use cwb_mount_celestron::stoptest::{self, StopTest, rate_arcsec_s};
    use std::io::{IsTerminal, Write};

    let every = std::time::Duration::from_millis(250);
    let spread = |r: &[stoptest::Reading]| -> [f64; 2] {
        [0, 1].map(|i| {
            let d: Vec<f64> = r
                .iter()
                .map(|x| ((x.deg[i] - r[0].deg[i] + 180.0).rem_euclid(360.0) - 180.0) * 3600.0)
                .collect();
            d.iter().cloned().fold(f64::MIN, f64::max) - d.iter().cloned().fold(f64::MAX, f64::min)
        })
    };
    println!("watching the mount for {:.0} s…", before.as_secs_f64());
    let before_r = stoptest::watch(&mut link, clock, before, every);
    if before_r.len() < 4 {
        anyhow::bail!(
            "couldn't read the mount's positions ({} readings)",
            before_r.len()
        );
    }
    let s = spread(&before_r);
    if s.iter().any(|v| *v > STILL_ARCSEC) {
        anyhow::bail!(
            "the mount isn't still (spread azimuth {:.2}″, altitude {:.2}″): power-cycle it first, so the test starts from still",
            s[0],
            s[1]
        );
    }
    println!(
        "still: azimuth {:.5}°, altitude {:.5}° ({} readings)",
        before_r[0].deg[0],
        before_r[0].deg[1],
        before_r.len()
    );
    let bytes = form.bytes(axis);
    let hex: Vec<String> = bytes.iter().map(|b| format!("{b:02X}")).collect();
    println!("will send {form} to {axis:?}: {}", hex.join(" "));
    if !yes {
        if !std::io::stdin().is_terminal() {
            anyhow::bail!("no terminal to confirm on: pass --yes to proceed");
        }
        print!("Send it? Stay by the power switch. [y/N] ");
        std::io::stdout().flush()?;
        let mut answer = String::new();
        std::io::stdin().read_line(&mut answer)?;
        if !answer.trim().eq_ignore_ascii_case("y") {
            println!("nothing sent");
            return Ok(ExitCode::FAILURE);
        }
    }
    let (sent_ns, outcome) = stoptest::send(&mut link, clock, axis, form);
    println!(
        "sent: {outcome:?}; watching for {:.0} s…",
        after.as_secs_f64()
    );
    let after_r = stoptest::watch(&mut link, clock, after, every);
    let rates = rate_arcsec_s(&after_r).unwrap_or([f64::NAN; 2]);
    let moved = spread(&after_r);
    let creeping: Vec<&str> = [("azimuth", 0), ("altitude", 1)]
        .iter()
        .filter(|(_, i)| moved[*i] > STILL_ARCSEC)
        .map(|(n, _)| *n)
        .collect();
    println!(
        "after: azimuth {:+.3}″/s ({:.2}″ in all), altitude {:+.3}″/s ({:.2}″ in all), {} readings",
        rates[0],
        moved[0],
        rates[1],
        moved[1],
        after_r.len()
    );
    if creeping.is_empty() {
        println!("result: {form} on {axis:?} left the mount still");
    } else {
        println!(
            "result: {form} on {axis:?} started a creep on {}. Power-cycle the mount before the next test.",
            creeping.join(" and ")
        );
    }
    let test = StopTest {
        axis,
        form,
        bytes: hex.join(" "),
        outcome,
        sent_ns,
        before: before_r,
        after: after_r,
    };
    fs::create_dir_all(out).with_context(|| format!("creating {}", out.display()))?;
    let file = out.join(format!(
        "{}_{form}_{}.json",
        cwb_storage::clock::utc_now().replace(':', "-"),
        match axis {
            cwb_mount_core::Axis::Azimuth => "azm",
            cwb_mount_core::Axis::Altitude => "alt",
        }
    ));
    fs::write(&file, serde_json::to_string_pretty(&test)? + "\n")?;
    println!("saved: {}", file.display());
    Ok(ExitCode::SUCCESS)
}

/// Arcsecond spread of each axis over `readings`, wrap-aware.
fn spread_arcsec(r: &[cwb_mount_celestron::stoptest::Reading]) -> [f64; 2] {
    [0, 1].map(|i| {
        let d: Vec<f64> = r
            .iter()
            .map(|x| ((x.deg[i] - r[0].deg[i] + 180.0).rem_euclid(360.0) - 180.0) * 3600.0)
            .collect();
        d.iter().cloned().fold(f64::MIN, f64::max) - d.iter().cloned().fold(f64::MAX, f64::min)
    })
}

fn cancel_sweep(
    mut link: impl cwb_celestron_discovery::Link,
    clock: &cwb_mount_celestron::adapter::Clock,
    axis: cwb_mount_core::Axis,
    watch: std::time::Duration,
    out: &Path,
    yes: bool,
) -> Result<ExitCode> {
    use cwb_mount_celestron::stoptest::{self, Cancel, Reading, StopForm, rate_arcsec_s};
    use std::io::{IsTerminal, Write};

    let every = std::time::Duration::from_millis(250);
    let ns = |s: f64| (s * 1e9) as i64;
    // Judge each window on its last 10 s, after any settling.
    let tail = |r: &[Reading]| -> Vec<Reading> {
        let end = r.last().map_or(0, |x| x.t_ns);
        r.iter()
            .filter(|x| x.t_ns >= end - ns(10.0))
            .copied()
            .collect()
    };
    let creeping = |r: &[Reading]| spread_arcsec(&tail(r))[axis.index()] > STILL_ARCSEC;
    let show = |label: &str, r: &[Reading]| {
        let rate = rate_arcsec_s(&tail(r)).unwrap_or([f64::NAN; 2]);
        println!(
            "{label}: azimuth {:+.3}″/s, altitude {:+.3}″/s ({} readings)",
            rate[0],
            rate[1],
            r.len()
        );
    };
    if !yes {
        if !std::io::stdin().is_terminal() {
            anyhow::bail!("no terminal to confirm on: pass --yes to proceed");
        }
        println!(
            "This starts a slow creep on {axis:?} (variable rate 0) if it's still, then tries:"
        );
        for c in Cancel::ALL {
            println!("  - {c}");
        }
        print!("Go ahead? Stay by the power switch. [y/N] ");
        std::io::stdout().flush()?;
        let mut answer = String::new();
        std::io::stdin().read_line(&mut answer)?;
        if !answer.trim().eq_ignore_ascii_case("y") {
            println!("nothing sent");
            return Ok(ExitCode::FAILURE);
        }
    }
    let mut record = serde_json::Map::new();
    let start = stoptest::watch(&mut link, clock, std::time::Duration::from_secs(5), every);
    if start.len() < 4 {
        anyhow::bail!("couldn't read the mount's positions");
    }
    show("at the start", &start);
    record.insert("start".into(), serde_json::to_value(&start)?);
    if !creeping(&start) {
        let (_, outcome) = stoptest::send(&mut link, clock, axis, StopForm::VariablePositive);
        println!("still; sent variable rate 0 to start the creep ({outcome:?})");
        let r = stoptest::watch(&mut link, clock, std::time::Duration::from_secs(10), every);
        show("creep", &r);
        record.insert("creep".into(), serde_json::to_value(&r)?);
        if !creeping(&r) {
            println!("result: variable rate 0 didn't start a creep this time; nothing to cancel");
            return Ok(ExitCode::FAILURE);
        }
    } else {
        println!("already creeping; testing cancels against it");
    }
    let mut tried = Vec::new();
    let mut found = None;
    for c in Cancel::ALL {
        let sent = stoptest::run_cancel(&mut link, axis, c);
        let r = stoptest::watch(&mut link, clock, watch, every);
        let still = !creeping(&r);
        println!(
            "{c}: {} → {}",
            sent.iter()
                .map(|(b, o)| format!("{b} ({o:?})"))
                .collect::<Vec<_>>()
                .join(", "),
            if still { "STILL" } else { "still creeping" }
        );
        show("  after", &r);
        tried.push(serde_json::json!({ "cancel": c, "sent": sent, "readings": r, "still": still }));
        if still {
            found = Some(c);
            break;
        }
    }
    record.insert("tried".into(), serde_json::Value::Array(tried));
    match found {
        Some(c) => println!("result: {c} cancelled the creep"),
        None => println!("result: nothing cancelled the creep. Power-cycle the mount."),
    }
    fs::create_dir_all(out).with_context(|| format!("creating {}", out.display()))?;
    let file = out.join(format!(
        "{}_cancel-sweep.json",
        cwb_storage::clock::utc_now().replace(':', "-")
    ));
    fs::write(&file, serde_json::to_string_pretty(&record)? + "\n")?;
    println!("saved: {}", file.display());
    Ok(if found.is_some() {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    })
}

/// Opens the hand controller's serial port. If it can't be opened (most
/// often after the hand controller restarts, when macOS keeps a device it
/// can't open), it beeps, says to re-plug the cable, and retries every
/// second until the port opens. Ctrl-C gives up.
fn open_serial(path: &str) -> cwb_celestron_discovery::SerialLink {
    use std::io::Write;
    let shown = cwb_celestron_discovery::redact_path(path);
    let mut waited = 0u32;
    loop {
        match cwb_celestron_discovery::SerialLink::open(path) {
            Ok(link) => {
                if waited > 0 {
                    println!("{shown} is open again");
                }
                return link;
            }
            Err(e) => {
                if waited.is_multiple_of(10) {
                    // The bell, every 10 s while waiting: easy to miss in the dark otherwise.
                    print!("\x07");
                    if waited == 0 {
                        println!(
                            "!! can't open {shown} ({}).\n!! Unplug the USB cable at the hand controller, wait 5 s, and plug it back in. Waiting for it… (Ctrl-C to give up; `cwb celestron ports` lists ports if its name changed)",
                            e.to_string().split(". ").next().unwrap_or_default()
                        );
                    }
                    let _ = std::io::stdout().flush();
                }
                waited += 1;
                std::thread::sleep(std::time::Duration::from_secs(1));
            }
        }
    }
}

fn backlash(
    mut link: impl cwb_celestron_discovery::Link,
    changes: &[(cwb_celestron_setup::backlash::Slot, u8)],
    yes: bool,
) -> Result<ExitCode> {
    use cwb_celestron_setup::{
        ReadBack,
        backlash::{self, Slot},
    };
    use std::io::{IsTerminal, Write};

    let show = |link: &mut dyn FnMut(Slot) -> Option<u8>| -> String {
        Slot::ALL
            .iter()
            .map(|s| format!("{s} {}", link(*s).map_or("—".into(), |v| v.to_string())))
            .collect::<Vec<_>>()
            .join(", ")
    };
    println!(
        "anti-backlash now: {}",
        show(&mut |s| backlash::read(&mut link, s))
    );
    if changes.is_empty() {
        return Ok(ExitCode::SUCCESS);
    }
    let plan = changes
        .iter()
        .map(|(s, v)| format!("{s}={v}"))
        .collect::<Vec<_>>()
        .join(", ");
    println!("will set: {plan}");
    if !yes {
        if !std::io::stdin().is_terminal() {
            anyhow::bail!("no terminal to confirm on: pass --yes to proceed");
        }
        print!("Send to the motor controllers? The mount must be still. [y/N] ");
        std::io::stdout().flush()?;
        let mut answer = String::new();
        std::io::stdin().read_line(&mut answer)?;
        if !answer.trim().eq_ignore_ascii_case("y") {
            println!("nothing sent");
            return Ok(ExitCode::FAILURE);
        }
    }
    let mut all = true;
    for (slot, value) in changes {
        let applied = backlash::set(&mut link, *slot, *value);
        all &= applied.confirmed();
        let text = match (&applied.read_back, applied.acknowledged) {
            (Some(ReadBack::Matches), _) => "set and confirmed by read-back".to_owned(),
            (Some(ReadBack::Differs(why)), _) => format!("acknowledged, but {why}"),
            (Some(ReadBack::NotAnswered(o)), _) => {
                format!("acknowledged, but the read-back went unanswered ({o:?})")
            }
            (None, o) => format!("not acknowledged ({o:?})"),
        };
        println!("{slot}={value}: {text}");
    }
    println!(
        "anti-backlash now: {}",
        show(&mut |s| backlash::read(&mut link, s))
    );
    Ok(if all {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    })
}

/// What `cwb celestron setup` will send. Coordinates are never printed:
/// only where they came from and their hemispheres.
struct SetupPlan {
    time_zone: Option<jiff::tz::TimeZone>,
    /// The site to send, and where it came from.
    location: Option<(cwb_celestron_setup::Site, String)>,
}

impl SetupPlan {
    fn load(
        path: &Path,
        db: Option<&Path>,
        from: LocationFrom,
        time: bool,
        location: bool,
    ) -> Result<Self> {
        let site_file = || -> Result<cwb_celestron_setup::Site> {
            let text = fs::read_to_string(path).with_context(|| {
                format!(
                    "reading {}: copy config/site.example.toml there and fill it in, or pass --site",
                    path.display()
                )
            })?;
            Ok(cwb_celestron_setup::Site::parse(&text)?)
        };
        // The site file can name the time zone even when the location comes
        // from the phone.
        let file = if path.exists() {
            Some(site_file()?)
        } else {
            None
        };
        let location = if !location {
            None
        } else {
            let phone = match (from, db) {
                (LocationFrom::SiteFile, _) => None,
                (LocationFrom::Phone, None) => {
                    anyhow::bail!("--location-from phone needs --db or CWB_DB")
                }
                (_, None) => None,
                (_, Some(db)) => {
                    let conn = cwb_storage::open_read_only(db)
                        .with_context(|| format!("opening {}", db.display()))?;
                    sessions::latest_fix(&conn, PHONE_FIX_MAX_ACCURACY_M)?
                }
            };
            Some(match (phone, from) {
                (Some(fix), _) => (
                    cwb_celestron_setup::Site {
                        name: None,
                        latitude: fix.location.latitude,
                        longitude: fix.location.longitude,
                        time_zone: None,
                    },
                    format!(
                        "the phone's fix in session {} ({}, {}, ±{:.0} m)",
                        &fix.session_id[..8],
                        fix.session_created_utc,
                        fix.environment,
                        fix.location.horizontal_accuracy_m
                    ),
                ),
                (None, LocationFrom::Phone) => anyhow::bail!(
                    "no precise phone fix within {PHONE_FIX_MAX_ACCURACY_M} m in the database"
                ),
                (None, _) => {
                    let site = match file.clone() {
                        Some(site) => site,
                        None => site_file()?,
                    };
                    let from = format!(
                        "site {:?} from {}",
                        site.name.as_deref().unwrap_or("unnamed"),
                        path.display()
                    );
                    (site, from)
                }
            })
        };
        let time_zone = if time {
            Some(match file.as_ref().and_then(|s| s.time_zone.as_deref()) {
                Some(name) => jiff::tz::TimeZone::get(name)
                    .with_context(|| format!("time zone {name:?} in {}", path.display()))?,
                None => jiff::tz::TimeZone::try_system().context("this Mac's time zone")?,
            })
        } else {
            None
        };
        Ok(Self {
            time_zone,
            location,
        })
    }
}

fn setup(
    mut link: impl cwb_celestron_discovery::Link,
    plan: &SetupPlan,
    yes: bool,
) -> Result<ExitCode> {
    use cwb_celestron_discovery::{HandController, Query, query::Value};
    use cwb_celestron_setup::{HandTime, Location, ReadBack, apply};
    use std::io::{IsTerminal, Write};

    // Make sure something that speaks the protocol is there before changing it.
    let mut hc = HandController::new(link);
    let ok = matches!(hc.query(Query::Echo(b'x')).value, Some(Value::Echo(b'x')));
    let model = hc.query(Query::Model).value.clone();
    link = hc.into_parts().0;
    if !ok {
        anyhow::bail!(
            "the hand controller didn't echo: check the port, cable and that it has finished starting up"
        );
    }
    println!(
        "hand controller answering; model {}",
        model.map_or("unknown".into(), |m| m.to_string())
    );

    if let Some(tz) = &plan.time_zone {
        let now = HandTime::at(jiff::Timestamp::now(), tz)?;
        println!(
            "will set time: this Mac's clock in {}, now {now}",
            tz.iana_name().unwrap_or("this Mac's time zone")
        );
    }
    if let Some((site, from)) = &plan.location {
        println!(
            "will set location: {from} ({}; coordinates not shown)",
            site.hemispheres()
        );
    }
    if !yes {
        if !std::io::stdin().is_terminal() {
            anyhow::bail!("no terminal to confirm on: pass --yes to proceed");
        }
        print!("Send to the hand controller? Leave it at its top-level screen. [y/N] ");
        std::io::stdout().flush()?;
        let mut answer = String::new();
        std::io::stdin().read_line(&mut answer)?;
        if !answer.trim().eq_ignore_ascii_case("y") {
            println!("nothing sent");
            return Ok(ExitCode::FAILURE);
        }
    }

    let mut all = true;
    let mut report = |what: &str, applied: apply::Applied| {
        let text = match (&applied.read_back, applied.acknowledged) {
            (Some(ReadBack::Matches), _) => "set and confirmed by read-back".to_owned(),
            (Some(ReadBack::Differs(why)), _) => format!("set, but {why}"),
            (Some(ReadBack::NotAnswered(o)), _) => {
                format!("acknowledged, but the read-back went unanswered ({o:?})")
            }
            (None, o) => format!("not acknowledged ({o:?}): nothing confirmed"),
        };
        all &= applied.confirmed();
        println!("{what:<9} {text}");
    };
    if let Some(tz) = &plan.time_zone {
        std::thread::sleep(apply::until_next_second(jiff::Timestamp::now()));
        let time = HandTime::at(jiff::Timestamp::now(), tz)?;
        report("time", apply::set_time(&mut link, &time));
    }
    if let Some((site, _)) = &plan.location {
        report(
            "location",
            apply::set_location(&mut link, &Location::of(site)),
        );
    }
    Ok(if all {
        ExitCode::SUCCESS
    } else {
        ExitCode::FAILURE
    })
}

fn analyze(
    db: &Path,
    session: &str,
    config: Option<&Path>,
    out: Option<PathBuf>,
    device: Option<&str>,
) -> Result<ExitCode> {
    let text = match config {
        Some(path) => {
            fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?
        }
        None => cwb_analysis::config::STATIONARY.to_owned(),
    };
    let config = cwb_analysis::Config::parse(&text)?;
    let conn =
        cwb_storage::open_read_only(db).with_context(|| format!("opening {}", db.display()))?;
    let id = sessions::resolve(&conn, session)?;
    let data = cwb_analysis::load(&conn, &id, device)?;
    let analysis = cwb_analysis::analyze(&data, &config, &cwb_analysis::config::sha256(&text));
    let out = out.unwrap_or_else(|| PathBuf::from("reports").join(&id[..8]));
    fs::create_dir_all(&out).with_context(|| format!("creating {}", out.display()))?;
    for (name, contents) in cwb_analysis::report::render(&analysis, &data) {
        fs::write(out.join(name), contents)?;
    }
    println!("session {id}: {}", analysis.decision);
    println!(
        "  {:.1} s, {} still window(s), {:.1} s steady state, {} move(s)",
        analysis.duration_s,
        analysis.windows.len(),
        analysis.steady_state_s,
        analysis.moves.len()
    );
    if let Some(r) = &analysis.resolution {
        // Smallest resolvable step between two settle windows of a few lengths.
        let step = |v: Option<f64>| {
            v.map_or("    -   ".into(), |v| {
                format!("{:.4}°", r.coverage_k * std::f64::consts::SQRT_2 * v)
            })
        };
        println!(
            "  smallest step (k = {}), by settle-window length:",
            r.coverage_k
        );
        println!(
            "    {:<13} {:>9} {:>9} {:>9}   best (window)",
            "channel", "1 s", "2 s", "5 s"
        );
        for (i, (name, unit)) in r.channels.iter().enumerate() {
            if *unit != "deg" {
                continue;
            }
            let at = |tau: f64| {
                r.rows
                    .iter()
                    .find(|row| row.tau_s == tau)
                    .and_then(|row| row.adev[i])
            };
            println!(
                "    {name:<13} {:>9} {:>9} {:>9}   {}",
                step(at(1.0)),
                step(at(2.0)),
                step(at(5.0)),
                r.minimum[i].map_or("-".into(), |(tau, v)| format!(
                    "{} ({tau:.1} s)",
                    step(Some(v))
                ))
            );
        }
    }
    println!("report: {}", out.join("report.html").display());
    Ok(ExitCode::SUCCESS)
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
    init_logging_at("info");
}

fn init_logging_at(default: &str) {
    use tracing_subscriber::EnvFilter;
    tracing_subscriber::fmt()
        .with_env_filter(
            EnvFilter::try_from_default_env().unwrap_or_else(|_| EnvFilter::new(default)),
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
                    "{}  {}  {:<10}  {:<11}  {:>9} samples  {:>3} markers{}",
                    s.session_id,
                    s.created_utc,
                    s.status,
                    s.environment.as_deref().unwrap_or("—"),
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
                "session {} ({}): {} samples stored, {} already present, {} conflicting, {} markers, {} events, {} sites, {} clock exchanges",
                summary.session_id.as_deref().unwrap_or("?"),
                if summary.created { "new" } else { "existing" },
                summary.stored_samples,
                summary.duplicate_samples,
                summary.conflicting_samples,
                summary.markers,
                summary.events,
                summary.sites,
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
