//! `cwb mount run`: the interactive mount test runner (plan Prompt 8, ADR
//! 0013). This is the only command that can move a mount.
//!
//! It checks the hand controller ([`prepare`]), starts the receiver with a
//! tap so phone samples reach the runner live, and then feeds operator
//! lines, phone messages and a 5 ms tick to [`Runner`]. With `--simulate`
//! the same adapter talks to a simulated hand controller and mount instead,
//! and the simulated mount supplies the IMU.

use std::{
    fs::{self, File},
    io::{BufRead, BufWriter},
    net::SocketAddr,
    path::PathBuf,
    process::ExitCode,
    sync::{Arc, Mutex},
    time::Duration,
};

use anyhow::{Context, Result};
use cwb_celestron_discovery::{Link, redact_path};
use cwb_mount_celestron::{
    CelestronAdapter, CelestronSettings, adapter::Clock, fake::SimHandController, prepare::prepare,
};
use cwb_mount_core::Nanos;
use cwb_mount_runner::{Kind, Out, RunLog, Runner, RunnerConfig};
use cwb_mount_sim::{SimFaults, SimMount};
use cwb_receiver::{Server, Tapped, advertise::Advertisement, writer};
use cwb_storage::MacClock;
use tokio::sync::mpsc;

/// How often the adapter reads the mount's axis positions when idle.
const POSITION_EVERY: Duration = Duration::from_millis(250);
/// After quitting, keep ticking this long so stops are confirmed and logged.
const WIND_DOWN: Duration = Duration::from_millis(1500);
const TICK: Duration = Duration::from_millis(5);

pub struct Options {
    pub port: Option<String>,
    pub simulate: bool,
    pub config: PathBuf,
    pub db: Option<PathBuf>,
    pub listen: SocketAddr,
    pub name: String,
    pub advertise: bool,
    pub out: PathBuf,
}

pub fn run(options: Options) -> Result<ExitCode> {
    let text = fs::read_to_string(&options.config)
        .with_context(|| format!("reading {}", options.config.display()))?;
    let config = RunnerConfig::parse(&text)
        .map_err(|e| anyhow::anyhow!("{}: {e}", options.config.display()))?;
    let clock = Arc::new(MacClock::new());
    let now: Clock = {
        let clock = clock.clone();
        Arc::new(move || clock.now_ns())
    };
    let dir = options
        .out
        .join(cwb_storage::clock::utc_now().replace(':', "-"));
    fs::create_dir_all(&dir).with_context(|| format!("creating {}", dir.display()))?;
    let log_path = dir.join("run.ndjson");
    let log = RunLog::new(Box::new(BufWriter::new(
        File::create(&log_path).with_context(|| format!("creating {}", log_path.display()))?,
    )));

    if options.simulate {
        let mount = Arc::new(Mutex::new(SimMount::new(SimFaults::default(), 30.0, 1)));
        let link = SimHandController::new(mount.clone(), now.clone());
        let adapter = start_adapter(
            link,
            config.celestron,
            now.clone(),
            "simulated hand controller",
        )?;
        println!("SIMULATED: no hardware, no phone. The simulated mount supplies the IMU.");
        let (runner, out) = Runner::new(config, adapter, log, true, clock.boot_id(), now())
            .map_err(anyhow::Error::msg)?;
        print(&out);
        let result = super::runtime()?.block_on(drive(runner, now, None, Some(mount), None));
        println!("run log: {}", log_path.display());
        return result;
    }

    let path = options
        .port
        .clone()
        .context("--port is required without --simulate")?;
    let db = options
        .db
        .clone()
        .context("--db or CWB_DB is required: the phone's samples are stored there")?;
    let result = super::runtime()?.block_on(async {
        // Claim the phone's port first, so a busy port fails before the
        // hand controller is touched or the checklist is shown.
        let store = super::store(&db, &clock)?;
        let (writer, thread) = writer::spawn(store, 256);
        let (tap, taps) = mpsc::channel(4096);
        let server = Server::bind(options.listen, writer.clone(), clock.clone())
            .await
            .with_context(|| format!("listening on port {}", options.listen.port()))?
            .with_tap(tap);
        let port = server.local_addr()?.port();
        let _advertisement = options
            .advertise
            .then(|| Advertisement::start(&options.name, port).ok())
            .flatten();
        println!(
            "receiving phone data on port {port}{}",
            if options.advertise {
                format!(" as \"{}\"", options.name)
            } else {
                String::new()
            }
        );
        let link = super::open_serial(&path);
        let settings = config.celestron;
        let adapter = start_adapter(link, settings, now.clone(), &redact_path(&path))?;
        let (runner, out) = Runner::new(config, adapter, log, true, clock.boot_id(), now())
            .map_err(anyhow::Error::msg)?;
        print(&out);
        let (stop_server, stopped) = tokio::sync::oneshot::channel::<()>();
        let server = tokio::spawn(server.run(async {
            let _ = stopped.await;
        }));
        let reconnect = Reconnect { path, settings };
        let result = drive(runner, now, Some(taps), None, Some(reconnect)).await;
        let _ = stop_server.send(());
        let _ = server.await;
        writer
            .shutdown("mount runner stopped before bye")
            .await
            .context("stopping the database writer")?;
        drop(writer);
        tokio::task::spawn_blocking(move || thread.join())
            .await?
            .map_err(|_| anyhow::anyhow!("database writer panicked"))?;
        result
    });
    println!("run log: {}", log_path.display());
    result
}

/// How to reopen the hand controller's port after the link is lost.
struct Reconnect {
    path: String,
    settings: CelestronSettings,
}

/// Waits for the port (beeping and asking for a re-plug if it can't be
/// opened), then checks the hand controller again. Retries while the hand
/// controller is still starting up; gives up only if a check can't pass by
/// waiting (anti-backlash not 0).
fn reconnect(r: &Reconnect, now: Clock) -> Option<CelestronAdapter> {
    loop {
        let link = super::open_serial(&r.path);
        match start_adapter(link, r.settings, now.clone(), &redact_path(&r.path)) {
            Ok(adapter) => return Some(adapter),
            Err(e) if e.to_string().contains("anti-backlash") => {
                println!("!! {e:#}\n!! Not reconnecting: fix that and restart the runner.");
                return None;
            }
            Err(e) => {
                println!("!! {e:#}; trying again in 2 s");
                std::thread::sleep(Duration::from_secs(2));
            }
        }
    }
}

fn start_adapter<L: Link + Send + 'static>(
    link: L,
    settings: CelestronSettings,
    now: Clock,
    name: &str,
) -> Result<CelestronAdapter> {
    println!("checking the hand controller on {name}…");
    let (link, prepared) = prepare(link);
    let prepared = prepared.map_err(anyhow::Error::msg)?;
    let id = &prepared.identity;
    println!(
        "hand controller {}, model {}, motors {} / {}; mount at azimuth {:.4}°, altitude {:.4}° (its own angles)",
        id.controller_version.as_deref().unwrap_or("?"),
        id.model.as_deref().unwrap_or("?"),
        id.motor_versions[0].as_deref().unwrap_or("?"),
        id.motor_versions[1].as_deref().unwrap_or("?"),
        prepared.positions_deg[0],
        prepared.positions_deg[1],
    );
    for note in &prepared.notes {
        println!("note: {note}");
    }
    let [[azp, azn], [alp, aln]] = prepared.backlash;
    let want = settings.anti_backlash;
    if [azp, azn, alp, aln] != want.map(Some) {
        let show = |v: Option<u8>| v.map_or("—".into(), |v| v.to_string());
        anyhow::bail!(
            "anti-backlash is azm+ {}, azm- {}, alt+ {}, alt- {}, but config/mount.toml expects {}, {}, {}, {} ([celestron] anti_backlash). Set it with `cwb celestron backlash --port … --set azm+=N …`, or change the config.",
            show(azp),
            show(azn),
            show(alp),
            show(aln),
            want[0],
            want[1],
            want[2],
            want[3]
        );
    }
    if want == [0; 4] {
        println!("anti-backlash 0 on both axes");
    } else {
        println!(
            "anti-backlash azm+ {}, azm- {}, alt+ {}, alt- {}, as configured",
            want[0], want[1], want[2], want[3]
        );
    }
    Ok(CelestronAdapter::spawn(
        link,
        settings,
        now,
        Some(POSITION_EVERY),
    ))
}

async fn drive(
    mut runner: Runner<CelestronAdapter>,
    now: Clock,
    mut taps: Option<mpsc::Receiver<Tapped>>,
    sim: Option<Arc<Mutex<SimMount>>>,
    reconnect_with: Option<Reconnect>,
) -> Result<ExitCode> {
    let reconnect_with = reconnect_with.map(Arc::new);
    // A reconnection in progress delivers its adapter here.
    let mut reconnecting: Option<tokio::sync::oneshot::Receiver<Option<CelestronAdapter>>> = None;
    let (line_tx, mut lines) = mpsc::channel::<String>(16);
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            let Ok(line) = line else { break };
            if line_tx.blocking_send(line).is_err() {
                return;
            }
        }
        let _ = line_tx.blocking_send("quit".into());
    });
    let mut tick = tokio::time::interval(TICK);
    tick.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
    let mut last_step: Nanos = now();
    let mut last_imu: Nanos = now();
    let mut quit_at: Option<tokio::time::Instant> = None;
    loop {
        tokio::select! {
            Some(line) = lines.recv() => print(&runner.line(&line, now())),
            Some(t) = recv(&mut taps) => print(&runner.tapped(&t, now())),
            _ = tokio::signal::ctrl_c() => print(&runner.quit(now())),
            Some(result) = recv_adapter(&mut reconnecting) => {
                reconnecting = None;
                if let Some(adapter) = result {
                    print(&runner.replace_adapter(adapter, now()));
                }
            }
            _ = tick.tick() => {
                let t = now();
                if let Some(mount) = &sim {
                    let observation = {
                        let mut m = mount.lock().expect("sim mount");
                        m.step(t, t - last_step);
                        last_step = t;
                        (t - last_imu >= 10_000_000).then(|| {
                            last_imu = t;
                            m.observation(t)
                        }).flatten()
                    };
                    if let Some(o) = observation {
                        print(&runner.observation(o, t));
                    }
                }
                print(&runner.tick(t));
                if let Some(r) = &reconnect_with
                    && reconnecting.is_none()
                    && runner.link_lost()
                    && !runner.finished()
                {
                    runner.close_link(t);
                    print!("\x07");
                    println!("!! the hand controller link is down; reconnecting (moves stay disabled until it's back and you reset and arm)");
                    let (tx, rx) = tokio::sync::oneshot::channel();
                    let (r, now) = (r.clone(), now.clone());
                    // A plain thread: waiting for a re-plug can take any time,
                    // and quitting mustn't wait for it.
                    std::thread::spawn(move || {
                        let _ = tx.send(reconnect(&r, now));
                    });
                    reconnecting = Some(rx);
                }
            }
        }
        if runner.finished() {
            let deadline = *quit_at.get_or_insert_with(|| tokio::time::Instant::now() + WIND_DOWN);
            if tokio::time::Instant::now() >= deadline {
                break;
            }
        }
    }
    Ok(ExitCode::SUCCESS)
}

async fn recv_adapter(
    pending: &mut Option<tokio::sync::oneshot::Receiver<Option<CelestronAdapter>>>,
) -> Option<Option<CelestronAdapter>> {
    match pending {
        Some(rx) => rx.await.ok(),
        None => std::future::pending().await,
    }
}

async fn recv(taps: &mut Option<mpsc::Receiver<Tapped>>) -> Option<Tapped> {
    match taps {
        Some(rx) => rx.recv().await,
        None => std::future::pending().await,
    }
}

fn print(out: &[Out]) {
    for o in out {
        match o.kind {
            Kind::Info => println!("{}", o.text),
            Kind::Alert => println!("!! {}", o.text),
            Kind::Prompt => println!("> {}", o.text),
        }
    }
}
