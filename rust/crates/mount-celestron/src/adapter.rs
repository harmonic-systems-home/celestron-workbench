//! The adapter: a worker thread owns the serial link, so a slow reply (up to
//! 3.5 s, ADR 0010) never blocks the controller's checks. Commands queue to
//! the worker; acknowledgements, link loss and the mount's own axis
//! positions come back through [`MountAdapter::poll`].
//!
//! After a goto (ADR 0014) the worker watches its axis: it reads the motor
//! controller's position and goto-finished flag in turn, as fast as replies
//! come, between commands, and reports both. The watch outlasts a stop, so
//! the record shows whether the stop ended the goto, and ends once the flag
//! reads done and a position read repeats the one before.
//!
//! Tracking off and fixed rate 0 don't end a goto on these motor controllers
//! (docs/observations.md, O11), so a stop for an axis with a goto still
//! running first re-aims the goto, slowly, at the position just read there.

use std::{
    sync::{
        Arc,
        mpsc::{self, RecvTimeoutError},
    },
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

use cwb_celestron_discovery::{
    Link, Outcome, Query,
    query::{Device, Value},
    transact,
};
use cwb_mount_core::{
    Axis, CommandId, GotoSpeed, MountAdapter, MountCommand, MountReport, Nanos, TransportError,
};

use crate::encode::{CelestronSettings, Tx, goto_motor, transactions};

/// Consecutive unanswered commands before the link counts as lost: the USB
/// adapter can stay up while the hand controller or its cable is gone.
pub const TIMEOUTS_UNTIL_LOST: u32 = 3;

/// The mount's own axis angles, read from the motor controllers (the same
/// counts the hand controller's `z` reports), relative to power-on.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Position {
    /// Mac time the reply arrived.
    pub t_ns: Nanos,
    pub deg: [f64; 2],
}

/// One motion command's serial exchange: when it went out, when the reply
/// came, and what it was. Stop timing is measured from these.
#[derive(Debug, Clone, PartialEq, serde::Serialize)]
pub struct Transaction {
    pub sent_ns: Nanos,
    pub reply_ns: Nanos,
    pub bytes: Vec<u8>,
    pub outcome: Outcome,
}

enum Event {
    /// A move's or goto's first transaction is going out now.
    Sent(CommandId, Nanos),
    /// Every transaction of a move or goto succeeded.
    Ack(CommandId),
    /// A goto watch's reading.
    Watch(MountReport),
    Transaction(Transaction),
    Lost(String),
    Position(Position),
    Note(String),
}

pub type Clock = Arc<dyn Fn() -> Nanos + Send + Sync>;

pub struct CelestronAdapter {
    jobs: Option<mpsc::Sender<MountCommand>>,
    events: mpsc::Receiver<Event>,
    lost: bool,
    positions: Vec<Position>,
    transactions: Vec<Transaction>,
    notes: Vec<String>,
    worker: Option<JoinHandle<()>>,
}

impl CelestronAdapter {
    /// Starts the worker. With `position_every`, it reads the mount's axis
    /// positions whenever no command has arrived for that long.
    pub fn spawn<L: Link + Send + 'static>(
        link: L,
        signs: CelestronSettings,
        clock: Clock,
        position_every: Option<Duration>,
    ) -> Self {
        let (jobs, rx) = mpsc::channel();
        let (tx, events) = mpsc::channel();
        let worker = thread::Builder::new()
            .name("cwb-celestron".into())
            .spawn(move || {
                Worker {
                    link,
                    signs,
                    clock,
                    events: tx,
                    timeouts: 0,
                    moving: false,
                    watch: None,
                }
                .run(rx, position_every)
            })
            .expect("spawn the Celestron worker thread");
        Self {
            jobs: Some(jobs),
            events,
            lost: false,
            positions: Vec::new(),
            transactions: Vec::new(),
            notes: Vec::new(),
            worker: Some(worker),
        }
    }

    /// Axis positions read since the last call.
    pub fn take_positions(&mut self) -> Vec<Position> {
        std::mem::take(&mut self.positions)
    }

    /// Whether the link has been reported lost.
    pub fn is_lost(&self) -> bool {
        self.lost
    }

    /// Stops both axes if it still can, then closes the serial port so it
    /// can be reopened. The adapter is inert afterwards.
    pub fn close(&mut self) {
        self.jobs = None;
        self.lost = true;
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }

    /// Motion commands' serial exchanges since the last call.
    pub fn take_transactions(&mut self) -> Vec<Transaction> {
        std::mem::take(&mut self.transactions)
    }

    /// Things the operator should know that aren't faults by themselves.
    pub fn take_notes(&mut self) -> Vec<String> {
        std::mem::take(&mut self.notes)
    }
}

impl MountAdapter for CelestronAdapter {
    fn send(&mut self, command: &MountCommand, _now: Nanos) -> Result<(), TransportError> {
        let is_stop = command.is_stop();
        // Stops are always attempted, even over a link that looks lost.
        if (!self.lost || is_stop)
            && let Some(jobs) = &self.jobs
            && jobs.send(command.clone()).is_err()
        {
            self.lost = true;
        }
        if self.lost {
            Err(TransportError("the hand controller link is lost".into()))
        } else {
            Ok(())
        }
    }

    fn poll(&mut self, _now: Nanos) -> Vec<MountReport> {
        let mut reports = Vec::new();
        while let Ok(event) = self.events.try_recv() {
            match event {
                Event::Sent(id, sent_ns) => reports.push(MountReport::Sent { id, sent_ns }),
                Event::Ack(id) => reports.push(MountReport::Acknowledged(id)),
                Event::Watch(report) => reports.push(report),
                Event::Lost(why) => {
                    if !self.lost {
                        self.lost = true;
                        reports.push(MountReport::TransportLost);
                        self.notes.push(why);
                    }
                }
                Event::Position(p) => self.positions.push(p),
                Event::Transaction(t) => self.transactions.push(t),
                Event::Note(n) => self.notes.push(n),
            }
        }
        reports
    }
}

impl Drop for CelestronAdapter {
    /// Closing the queue makes the worker stop both axes, then exit.
    fn drop(&mut self) {
        self.close();
    }
}

struct Worker<L: Link> {
    link: L,
    signs: CelestronSettings,
    clock: Clock,
    events: mpsc::Sender<Event>,
    timeouts: u32,
    /// A move has been sent and no stop since. Positions aren't read then:
    /// the hand controller answers `z` slowly while a motor slews (hundreds
    /// of ms), and a stop must never wait behind it.
    moving: bool,
    watch: Option<Watch>,
}

/// Reading a goto's axis between commands.
struct Watch {
    axis: Axis,
    position_next: bool,
    /// The goto-finished flag has read done.
    finished: bool,
    last: Option<u32>,
}

impl<L: Link> Worker<L> {
    fn run(mut self, jobs: mpsc::Receiver<MountCommand>, position_every: Option<Duration>) {
        // Stops re-sent every 250 ms while a fault is latched mustn't starve
        // the position reads: they are the best evidence the mount is still.
        let mut last_read = Instant::now();
        loop {
            let first = match position_every {
                // Watching a goto: read between commands, never waiting.
                _ if self.watch.is_some() => jobs.try_recv().map_err(|e| match e {
                    mpsc::TryRecvError::Empty => RecvTimeoutError::Timeout,
                    mpsc::TryRecvError::Disconnected => RecvTimeoutError::Disconnected,
                }),
                Some(every) => jobs.recv_timeout(every.saturating_sub(last_read.elapsed())),
                None => jobs.recv().map_err(|_| RecvTimeoutError::Disconnected),
            };
            let read_due = position_every.is_some_and(|every| last_read.elapsed() >= every);
            match first {
                Ok(command) => {
                    let mut batch = vec![command];
                    batch.extend(jobs.try_iter());
                    for command in overtake(batch) {
                        self.execute(&command);
                    }
                    if read_due && !self.moving && self.watch.is_none() {
                        last_read = Instant::now();
                        self.read_position();
                    }
                }
                Err(RecvTimeoutError::Timeout) if self.watch.is_none() && !self.moving => {
                    last_read = Instant::now();
                    self.read_position();
                }
                Err(RecvTimeoutError::Timeout) if self.watch.is_some() => self.read_watch(),
                Err(RecvTimeoutError::Timeout) => {}
                Err(RecvTimeoutError::Disconnected) => {
                    self.execute(&MountCommand::StopAll);
                    return;
                }
            }
        }
    }

    fn execute(&mut self, command: &MountCommand) {
        // A stop keeps any goto watch going; anything else replaces it.
        self.moving = !command.is_stop();
        let motion_id = match *command {
            MountCommand::Move { id, .. } | MountCommand::Goto { id, .. } => Some(id),
            _ => None,
        };
        if !command.is_stop() {
            self.watch = None;
        }
        // The re-aim goes first: tracking off and fixed rate 0 take about
        // 100 ms and don't end a goto (O11).
        if command.is_stop() {
            self.retarget(command);
        }
        let mut all_ok = true;
        let mut first = true;
        for tx in transactions(command, self.signs) {
            if first && let Some(id) = motion_id {
                let _ = self.events.send(Event::Sent(id, (self.clock)()));
            }
            first = false;
            all_ok &= self.transmit(tx, command) == Outcome::Ok;
        }
        if all_ok && let Some(id) = motion_id {
            let _ = self.events.send(Event::Ack(id));
        }
        if let MountCommand::Goto { axis, .. } = *command {
            self.watch = Some(Watch {
                axis,
                position_next: true,
                finished: false,
                last: None,
            });
        }
    }

    /// Sends one transaction and reports it.
    fn transmit(&mut self, tx: Tx, command: &MountCommand) -> Outcome {
        let sent_ns = (self.clock)();
        let (outcome, _) = transact(&mut self.link, &tx.bytes, 0, tx.pass_through);
        let _ = self.events.send(Event::Transaction(Transaction {
            sent_ns,
            reply_ns: (self.clock)(),
            bytes: tx.bytes,
            outcome,
        }));
        self.outcome(outcome, command);
        outcome
    }

    /// After a stop: a goto still running on a stopped axis is re-aimed at
    /// the position read now, so it stops about there (O11).
    fn retarget(&mut self, stop: &MountCommand) {
        let Some(w) = &self.watch else {
            return;
        };
        let axis = w.axis;
        let stopped = match *stop {
            MountCommand::Stop { axis: a } => a == axis,
            _ => true,
        };
        if w.finished || !stopped {
            return;
        }
        let query = Query::MotorPosition(device_of(axis));
        let (outcome, reply) = transact(&mut self.link, &query.bytes(), query.reply_len(), true);
        let t_ns = (self.clock)();
        let Some(Value::MotorPosition { units, .. }) = (outcome == Outcome::Ok)
            .then(|| query.decode(&reply[..query.reply_len()]))
            .flatten()
        else {
            let _ = self.events.send(Event::Note(format!(
                "couldn't read the {axis:?} position to end its goto: it may run on to its target"
            )));
            return;
        };
        let _ = self.events.send(Event::Watch(MountReport::Position {
            axis,
            t_ns,
            units: self.signs.flip_units(axis, units),
        }));
        self.transmit(goto_motor(axis, units, GotoSpeed::Slow), stop);
    }

    /// One read for the goto watch: the position or the goto-finished flag,
    /// in turn.
    fn read_watch(&mut self) {
        let Some(w) = &self.watch else {
            return;
        };
        let (axis, position_next) = (w.axis, w.position_next);
        let query = if position_next {
            Query::MotorPosition(device_of(axis))
        } else {
            Query::SlewDone(device_of(axis))
        };
        let (outcome, reply) = transact(&mut self.link, &query.bytes(), query.reply_len(), true);
        let t_ns = (self.clock)();
        let decoded = (outcome == Outcome::Ok)
            .then(|| query.decode(&reply[..query.reply_len()]))
            .flatten();
        let Some(w) = &mut self.watch else {
            return;
        };
        let report = match decoded {
            Some(Value::MotorPosition { units, .. }) => {
                let units = self.signs.flip_units(axis, units);
                if w.finished && w.last == Some(units) {
                    self.watch = None;
                } else {
                    w.last = Some(units);
                }
                MountReport::Position { axis, t_ns, units }
            }
            Some(Value::Flag(done)) => {
                w.finished |= done;
                MountReport::SlewDone { axis, t_ns, done }
            }
            _ => {
                // Try the other reading next; the controller's deadline
                // covers a watch that never gets an answer.
                w.position_next = !w.position_next;
                self.link_health(if outcome == Outcome::Ok {
                    Outcome::Malformed
                } else {
                    outcome
                });
                return;
            }
        };
        self.timeouts = 0;
        if let Some(w) = &mut self.watch {
            w.position_next = !w.position_next;
        }
        let _ = self.events.send(Event::Watch(report));
    }

    fn outcome(&mut self, outcome: Outcome, command: &MountCommand) {
        match outcome {
            Outcome::Ok => self.timeouts = 0,
            Outcome::DeviceNoResponse => {
                self.timeouts = 0;
                let _ = self.events.send(Event::Note(format!(
                    "a motor controller didn't answer {command:?}"
                )));
            }
            Outcome::Timeout | Outcome::Malformed | Outcome::LinkError => self.link_health(outcome),
        }
    }

    /// Unanswered commands and a failed port count against the link,
    /// whether they were motion commands or position reads: a dead link must
    /// show before anything is armed, not when a move is sent.
    fn link_health(&mut self, outcome: Outcome) {
        match outcome {
            Outcome::Ok | Outcome::DeviceNoResponse => self.timeouts = 0,
            Outcome::Timeout | Outcome::Malformed => {
                self.timeouts += 1;
                if self.timeouts >= TIMEOUTS_UNTIL_LOST {
                    let _ = self.events.send(Event::Lost(format!(
                        "{} commands in a row went unanswered",
                        self.timeouts
                    )));
                }
            }
            Outcome::LinkError => {
                let _ = self.events.send(Event::Lost(
                    "the serial port failed (was the USB cable or hand controller reset? restart the runner)"
                        .into(),
                ));
            }
        }
    }

    /// Both axes' positions from the motor controllers (about 40 ms each),
    /// not the hand controller's `z`, which sometimes takes a second (O7)
    /// and holds up any command queued behind it. The same counts: `z`
    /// reports the motors' positions (ADR 0010).
    fn read_position(&mut self) {
        let mut deg = [0.0; 2];
        for axis in Axis::BOTH {
            let query = Query::MotorPosition(device_of(axis));
            let (outcome, reply) =
                transact(&mut self.link, &query.bytes(), query.reply_len(), true);
            match (outcome == Outcome::Ok)
                .then(|| query.decode(&reply[..query.reply_len()]))
                .flatten()
            {
                Some(Value::MotorPosition { deg: d, .. }) => deg[axis.index()] = d,
                _ => {
                    self.link_health(if outcome == Outcome::Ok {
                        Outcome::Malformed
                    } else {
                        outcome
                    });
                    return;
                }
            }
        }
        self.timeouts = 0;
        let _ = self.events.send(Event::Position(Position {
            t_ns: (self.clock)(),
            deg,
        }));
    }
}

fn device_of(axis: Axis) -> Device {
    match axis {
        Axis::Azimuth => Device::AzmMotor,
        Axis::Altitude => Device::AltMotor,
    }
}

/// A stop overtakes any move or goto queued before it: once the controller
/// has asked for a stop, an older one must not start.
fn overtake(batch: Vec<MountCommand>) -> Vec<MountCommand> {
    let is_stop = MountCommand::is_stop;
    match batch.iter().rposition(is_stop) {
        Some(last_stop) => batch
            .into_iter()
            .enumerate()
            .filter(|(i, c)| *i >= last_stop || is_stop(c))
            .map(|(_, c)| c)
            .collect(),
        None => batch,
    }
}

#[cfg(test)]
mod tests {
    use cwb_mount_core::{Axis, Direction};

    use super::*;

    fn mv(id: CommandId) -> MountCommand {
        MountCommand::Move {
            id,
            axis: Axis::Azimuth,
            direction: Direction::Positive,
            rate_deg_s: 0.1,
            fixed_rate: None,
        }
    }

    #[test]
    fn a_stop_overtakes_moves_queued_before_it() {
        let stop = MountCommand::StopAll;
        assert_eq!(
            overtake(vec![mv(1), stop.clone()]),
            std::slice::from_ref(&stop)
        );
        assert_eq!(
            overtake(vec![mv(1), stop.clone(), mv(2)]),
            [stop.clone(), mv(2)]
        );
        assert_eq!(overtake(vec![mv(1)]), [mv(1)]);
    }
}
