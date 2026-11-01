//! A mount session for apps (ADR 0019): the tested Celestron adapter and the
//! interlock controller in encoder-only mode, driven by a thread of its own.
//! Everything here is safe Rust; `lib.rs` puts a C interface around it.

use std::{
    collections::VecDeque,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use cwb_celestron_discovery::{Link, SerialLink, redact_path};
use cwb_mount_celestron::{
    CelestronAdapter, CelestronSettings, adapter::Clock, fake::SimHandController, prepare::prepare,
};
use cwb_mount_core::{
    Action, Axis, Controller, EncoderObserver, GotoRequest, GotoSpeed, MountAdapter, MountCommand,
    MountReport, MountState, Nanos, SafetyConfig, deg_to_units, units_between, units_to_deg,
    wrap_units,
};
use cwb_mount_sim::{SimFaults, SimMount};

use crate::trace::{Trace, TracingLink};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

const MS: Nanos = 1_000_000;
/// The loop's tick: deadlines are checked at least this often.
const TICK: Duration = Duration::from_millis(5);
/// Idle position reads once armed, as the runner makes them.
const POSITION_EVERY: Duration = Duration::from_millis(250);
/// Idle position reads before arming: enough to show the altitude, and
/// little traffic through the hand controller while its keys are in use.
const POSITION_EVERY_UNARMED: Duration = Duration::from_secs(2);
/// How long an arm request keeps reads fast while unarmed.
const FAST_READS_FOR_ARMING: Nanos = 10_000 * MS;
/// Idle positions this far apart (units) are motion no command explains.
const CREEP_UNITS: i64 = 16;
/// Messages kept for the app to collect.
const MAX_MESSAGES: usize = 200;

/// How to open a session. `safety` and `celestron` are merged over the
/// defaults, so an app sets only what it changes; `safety.encoders_only` is
/// always on.
#[derive(Debug, Clone, Deserialize)]
pub struct OpenOptions {
    /// A serial device, or "simulate" for the simulated hand controller and mount.
    pub port: String,
    #[serde(default)]
    pub safety: Value,
    #[serde(default)]
    pub celestron: Value,
    /// A file for the session trace (see [`crate::trace`]), if wanted.
    #[serde(default)]
    pub trace: Option<String>,
}

/// What the hand controller reported when the session opened.
#[derive(Debug, Clone, Serialize)]
pub struct Opened {
    pub controller_version: Option<String>,
    pub model: Option<String>,
    pub motor_versions: [Option<String>; 2],
    /// azm+, azm−, alt+, alt−.
    pub anti_backlash: [Option<u8>; 4],
    pub positions_deg: [f64; 2],
    pub simulated: bool,
}

#[derive(Debug, Clone, Serialize)]
pub struct Status {
    pub state: String,
    /// The last idle read of each axis, in the axis's own angle.
    pub positions_deg: Option<[f64; 2]>,
    pub positions_age_ms: Option<i64>,
    /// The tube's true altitude, once a reference is set.
    pub altitude_deg: Option<f64>,
    pub link_lost: bool,
    /// The last command's record, and the latest fault.
    pub last_record: Option<Value>,
    pub last_fault: Option<Value>,
    /// Alerts and notes since the last status call.
    pub messages: Vec<String>,
}

struct Inner {
    controller: Controller,
    adapter: CelestronAdapter,
    observer: EncoderObserver,
    settings: CelestronSettings,
    sim: Option<Arc<Mutex<SimMount>>>,
    clock: Clock,
    last_step: Nanos,
    /// The last idle read: (time, axis-sense degrees, units).
    last_position: Option<(Nanos, [f64; 2], [u32; 2])>,
    /// When a command last ran: a goto starts only from a read made since.
    last_busy: Nanos,
    /// Idle units the creep check compares against.
    steady: Option<[u32; 2]>,
    messages: VecDeque<String>,
    next_request: u64,
    trace: Option<Trace>,
    /// The state at the last step, to trace changes.
    last_state: MountState,
    /// Fast reads while unarmed, until then (an arm request).
    fast_reads_until: Nanos,
    fast_reads: bool,
}

pub struct Session {
    inner: Arc<Mutex<Inner>>,
    stop: Arc<AtomicBool>,
    thread: Option<JoinHandle<()>>,
    pub opened: Opened,
}

impl Session {
    pub fn open(options: &OpenOptions) -> Result<Self, String> {
        let mut safety = serde_json::to_value(SafetyConfig::default()).expect("serializable");
        // Encoder reads pause for up to a second or so: between a goto's
        // watch and its stop, and when the hand controller stalls (O7).
        safety["imu_max_age_ms"] = json!(2_500);
        merge(&mut safety, &options.safety);
        safety["encoders_only"] = json!(true);
        let safety: SafetyConfig =
            serde_json::from_value(safety).map_err(|e| format!("safety: {e}"))?;
        let mut celestron =
            serde_json::to_value(CelestronSettings::default()).expect("serializable");
        merge(&mut celestron, &options.celestron);
        let settings: CelestronSettings =
            serde_json::from_value(celestron).map_err(|e| format!("celestron: {e}"))?;
        let controller = Controller::new(safety.clone()).map_err(|p| p.join("; "))?;

        let start = Instant::now();
        let clock: Clock = Arc::new(move || start.elapsed().as_nanos() as Nanos);
        let trace = match &options.trace {
            Some(path) => Some(
                Trace::create(path.as_ref(), clock.clone())
                    .map_err(|e| format!("couldn't create the trace: {e}"))?,
            ),
            None => None,
        };
        if let Some(t) = &trace {
            t.write(
                "open",
                json!({ "port": redact_path(&options.port), "safety": safety, "celestron": settings }),
            );
        }
        let (adapter, opened, sim) = if options.port == "simulate" {
            let mount = Arc::new(Mutex::new(SimMount::new(SimFaults::default(), 30.0, 1)));
            let link = SimHandController::new(mount.clone(), clock.clone());
            let (adapter, opened) = start_traced(link, &trace, settings, clock.clone(), true)?;
            (adapter, opened, Some(mount))
        } else {
            let link = SerialLink::open(&options.port)
                .map_err(|e| format!("couldn't open the hand controller's port: {e}"))?;
            let (adapter, opened) = start_traced(link, &trace, settings, clock.clone(), false)?;
            (adapter, opened, None)
        };
        if let Some(t) = &trace {
            t.write("opened", json!({ "opened": opened }));
        }
        let now = clock();
        let mut inner = Inner {
            controller,
            adapter,
            // An axis not read for a second is taken as still.
            observer: EncoderObserver::new(1_000 * MS),
            settings,
            sim,
            clock: clock.clone(),
            last_step: now,
            last_position: None,
            last_busy: 0,
            steady: None,
            messages: VecDeque::new(),
            next_request: 1,
            trace,
            last_state: MountState::Disconnected,
            fast_reads_until: 0,
            fast_reads: true,
        };
        let actions = inner.controller.connect(now).map_err(|r| r.0)?;
        inner.carry_out(actions, now);
        let inner = Arc::new(Mutex::new(inner));
        let stop = Arc::new(AtomicBool::new(false));
        let thread = {
            let inner = inner.clone();
            let stop = stop.clone();
            thread::Builder::new()
                .name("cwb-mount-session".into())
                .spawn(move || {
                    while !stop.load(Ordering::Relaxed) {
                        inner.lock().expect("session").step();
                        thread::sleep(TICK);
                    }
                })
                .map_err(|e| e.to_string())?
        };
        Ok(Self {
            inner,
            stop,
            thread: Some(thread),
            opened,
        })
    }

    /// One request from the app; see [`Request`].
    pub fn command(&self, request: Request) -> Result<Value, String> {
        let mut s = self.inner.lock().expect("session");
        let traced = format!("{request:?}");
        let result = s.command(request);
        if let Some(t) = &s.trace {
            let outcome = match &result {
                Ok(v) => v.clone(),
                Err(e) => json!({ "ok": false, "error": e }),
            };
            t.write("request", json!({ "request": traced, "result": outcome }));
        }
        result
    }

    pub fn status(&self) -> Status {
        let mut s = self.inner.lock().expect("session");
        let now = (s.clock)();
        Status {
            state: format!("{:?}", s.controller.state()),
            positions_deg: s.last_position.map(|p| p.1),
            positions_age_ms: s.last_position.map(|p| (now - p.0) / MS),
            altitude_deg: s.observer.altitude_deg(),
            link_lost: s.adapter.is_lost(),
            last_record: s
                .controller
                .records()
                .last()
                .map(|r| serde_json::to_value(r).expect("serializable")),
            last_fault: s
                .controller
                .faults()
                .last()
                .map(|f| serde_json::to_value(f).expect("serializable")),
            messages: s.messages.drain(..).collect(),
        }
    }
}

impl Drop for Session {
    /// Stops the mount, then the thread; the adapter stops both axes as it closes.
    fn drop(&mut self) {
        if let Ok(mut s) = self.inner.lock() {
            let now = (s.clock)();
            let actions = s.controller.shutdown(now);
            s.carry_out(actions, now);
        }
        self.stop.store(true, Ordering::Relaxed);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

/// What an app can ask of a session.
#[derive(Debug, Clone, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum Request {
    Arm,
    Disarm,
    Reset,
    Stop,
    EmergencyStop,
    /// The tube's true altitude now (the app computes it for the Moon it
    /// was just centred on), tying the altitude encoder to the sky.
    Reference {
        altitude_deg: f64,
    },
    /// A goto relative to the axis's last read position.
    Goto {
        axis: Axis,
        delta_deg: f64,
        #[serde(default)]
        fast: bool,
        #[serde(default)]
        approach: Option<cwb_mount_core::Direction>,
    },
}

impl Inner {
    fn command(&mut self, request: Request) -> Result<Value, String> {
        let now = (self.clock)();
        let result = match request {
            Request::Arm => {
                // Arming needs fresh reads: four a second for a while, so a
                // refused arm can be retried at once.
                self.fast_reads_until = now + FAST_READS_FOR_ARMING;
                self.controller.arm(now)
            }
            Request::Disarm => self.controller.disarm(now),
            Request::Reset => self.controller.reset(now),
            Request::Stop => Ok(self.controller.stop(now)),
            Request::EmergencyStop => Ok(self.controller.emergency_stop(now)),
            Request::Reference { altitude_deg } => {
                let Some((_, deg, _)) = self.last_position else {
                    return Err("no position read yet".into());
                };
                self.observer.set_altitude_reference(deg[1], altitude_deg);
                return Ok(json!({ "ok": true }));
            }
            Request::Goto {
                axis,
                delta_deg,
                fast,
                approach,
            } => {
                let start = self.goto_start(axis)?;
                let id = format!("app-{}", self.next_request);
                self.next_request += 1;
                let request = GotoRequest {
                    request_id: id.clone(),
                    axis,
                    delta_deg,
                    speed: if fast {
                        GotoSpeed::Fast
                    } else {
                        GotoSpeed::Slow
                    },
                    approach,
                };
                match self.controller.request_goto(request, start, now) {
                    Ok(actions) => {
                        self.last_busy = now;
                        self.carry_out(actions, now);
                        return Ok(json!({ "ok": true, "request_id": id }));
                    }
                    Err(refused) => Err(refused),
                }
            }
        };
        match result {
            Ok(actions) => {
                self.carry_out(actions, now);
                Ok(json!({ "ok": true }))
            }
            Err(refused) => Err(refused.0),
        }
    }

    fn step(&mut self) {
        let now = (self.clock)();
        if let Some(sim) = &self.sim {
            sim.lock()
                .expect("sim mount")
                .step(now, now - self.last_step);
        }
        self.last_step = now;
        for report in self.adapter.poll(now) {
            let actions = match report {
                MountReport::Sent { id, sent_ns } => self.controller.sent(id, sent_ns, now),
                MountReport::Acknowledged(id) => self.controller.acknowledged(id, now),
                MountReport::Position { axis, t_ns, units } => {
                    let mut a = self.controller.position(axis, t_ns, units, now);
                    if let Some(obs) =
                        self.observer
                            .reading(axis, t_ns, units_to_deg(i64::from(units)))
                    {
                        a.extend(self.controller.observe(obs, now));
                    }
                    a
                }
                MountReport::SlewDone { axis, t_ns, done } => {
                    self.controller.slew_done(axis, t_ns, done, now)
                }
                MountReport::TransportLost => self.controller.transport_lost(now),
            };
            self.carry_out(actions, now);
        }
        for p in self.adapter.take_positions() {
            let units = Axis::BOTH.map(|axis| {
                let motor = wrap_units(deg_to_units(p.deg[axis.index()]));
                self.settings.flip_units(axis, motor)
            });
            let deg = units.map(|u| units_to_deg(i64::from(u)));
            self.last_position = Some((p.t_ns, deg, units));
            if let Some(t) = &self.trace {
                t.write_at(p.t_ns, "position", json!({ "deg": deg }));
            }
            let mut actions = Vec::new();
            if let Some(obs) = self.observer.readings(p.t_ns, deg) {
                actions.extend(self.controller.observe(obs, now));
            }
            actions.extend(self.check_creep(units, now));
            self.carry_out(actions, now);
        }
        for note in self.adapter.take_notes() {
            self.message(note);
        }
        if matches!(
            self.controller.state(),
            MountState::Moving | MountState::Stopping
        ) {
            self.last_busy = now;
            self.steady = None;
        }
        let actions = self.controller.tick(now);
        self.carry_out(actions, now);
        let state = self.controller.state();
        if state != self.last_state {
            if let Some(t) = &self.trace {
                t.write_at(
                    now,
                    "state",
                    json!({ "from": format!("{:?}", self.last_state), "to": format!("{state:?}") }),
                );
            }
            self.last_state = state;
        }
        let unarmed = matches!(
            state,
            MountState::Disconnected | MountState::ConnectedReadOnly
        );
        let fast = !unarmed || now < self.fast_reads_until;
        if fast != self.fast_reads {
            self.fast_reads = fast;
            self.adapter.set_position_every(Some(if fast {
                POSITION_EVERY
            } else {
                POSITION_EVERY_UNARMED
            }));
        }
    }

    /// Motion too slow for the rate check, from idle reads drifting apart.
    fn check_creep(&mut self, units: [u32; 2], now: Nanos) -> Vec<Action> {
        if self.controller.state() != MountState::Armed
            || self.controller.active_command().is_some()
        {
            self.steady = None;
            return Vec::new();
        }
        let Some(steady) = self.steady else {
            self.steady = Some(units);
            return Vec::new();
        };
        let moved = Axis::BOTH
            .into_iter()
            .find(|a| units_between(steady[a.index()], units[a.index()]).abs() > CREEP_UNITS);
        match moved {
            Some(axis) => {
                self.steady = None;
                self.controller
                    .mount_moved(now, &format!("{axis:?} position changed with no command"))
            }
            None => Vec::new(),
        }
    }

    fn goto_start(&self, axis: Axis) -> Result<u32, String> {
        match self.last_position {
            Some((t, _, units)) if t > self.last_busy => Ok(units[axis.index()]),
            _ => Err("no position read since the mount last moved: wait a moment".into()),
        }
    }

    fn carry_out(&mut self, actions: Vec<Action>, now: Nanos) {
        let mut queue: VecDeque<Action> = actions.into();
        while let Some(action) = queue.pop_front() {
            match action {
                Action::Send(command) => {
                    if self.adapter.send(&command, now).is_err()
                        && !matches!(command, MountCommand::StopAll)
                    {
                        queue.extend(self.controller.transport_lost(now));
                    }
                }
                Action::Alert(text) => self.message(text),
            }
        }
    }

    fn message(&mut self, text: String) {
        if let Some(t) = &self.trace {
            t.write("message", json!({ "text": text }));
        }
        if self.messages.len() >= MAX_MESSAGES {
            self.messages.pop_front();
        }
        self.messages.push_back(text);
    }
}

/// Starts the adapter, over a traced link if there is a trace.
fn start_traced<L: Link + Send + 'static>(
    link: L,
    trace: &Option<Trace>,
    settings: CelestronSettings,
    clock: Clock,
    simulated: bool,
) -> Result<(CelestronAdapter, Opened), String> {
    match trace {
        Some(t) => start_adapter(
            TracingLink::new(link, t.clone()),
            settings,
            clock,
            simulated,
        ),
        None => start_adapter(link, settings, clock, simulated),
    }
}

fn start_adapter<L: Link + Send + 'static>(
    link: L,
    settings: CelestronSettings,
    clock: Clock,
    simulated: bool,
) -> Result<(CelestronAdapter, Opened), String> {
    let (link, prepared) = prepare(link);
    let p = prepared?;
    let [[azp, azn], [alp, aln]] = p.backlash;
    let opened = Opened {
        controller_version: p.identity.controller_version.clone(),
        model: p.identity.model.clone(),
        motor_versions: p.identity.motor_versions.clone(),
        anti_backlash: [azp, azn, alp, aln],
        positions_deg: p.positions_deg,
        simulated,
    };
    Ok((
        CelestronAdapter::spawn(link, settings, clock, Some(POSITION_EVERY)),
        opened,
    ))
}

/// Overlays `patch`'s fields onto `base`, recursively for objects.
fn merge(base: &mut Value, patch: &Value) {
    match (base, patch) {
        (Value::Object(b), Value::Object(p)) => {
            for (k, v) in p {
                merge(b.entry(k.clone()).or_insert(Value::Null), v);
            }
        }
        (b, p) if !p.is_null() => *b = p.clone(),
        _ => {}
    }
}
