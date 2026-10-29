//! The adapter: a worker thread owns the serial link, so a slow reply (up to
//! 3.5 s, ADR 0010) never blocks the controller's checks. Commands queue to
//! the worker; acknowledgements, link loss and the mount's own axis
//! positions come back through [`MountAdapter::poll`].

use std::{
    sync::{
        Arc,
        mpsc::{self, RecvTimeoutError},
    },
    thread::{self, JoinHandle},
    time::Duration,
};

use cwb_celestron_discovery::{Link, Outcome, Query, query::Value, transact};
use cwb_mount_core::{CommandId, MountAdapter, MountCommand, MountReport, Nanos, TransportError};

use crate::encode::{AxisSigns, transactions};

/// Consecutive unanswered commands before the link counts as lost: the USB
/// adapter can stay up while the hand controller or its cable is gone.
pub const TIMEOUTS_UNTIL_LOST: u32 = 3;

/// The mount's own axis angles (`z`), relative to power-on until aligned:
/// an independent motion record beside the IMU, not used for safety.
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Position {
    /// Mac time the reply arrived.
    pub t_ns: Nanos,
    pub deg: [f64; 2],
}

enum Event {
    Ack(CommandId),
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
    notes: Vec<String>,
    worker: Option<JoinHandle<()>>,
}

impl CelestronAdapter {
    /// Starts the worker. With `position_every`, it reads the mount's axis
    /// positions whenever no command has arrived for that long.
    pub fn spawn<L: Link + Send + 'static>(
        link: L,
        signs: AxisSigns,
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
                }
                .run(rx, position_every)
            })
            .expect("spawn the Celestron worker thread");
        Self {
            jobs: Some(jobs),
            events,
            lost: false,
            positions: Vec::new(),
            notes: Vec::new(),
            worker: Some(worker),
        }
    }

    /// Axis positions read since the last call.
    pub fn take_positions(&mut self) -> Vec<Position> {
        std::mem::take(&mut self.positions)
    }

    /// Things the operator should know that aren't faults by themselves.
    pub fn take_notes(&mut self) -> Vec<String> {
        std::mem::take(&mut self.notes)
    }
}

impl MountAdapter for CelestronAdapter {
    fn send(&mut self, command: &MountCommand, _now: Nanos) -> Result<(), TransportError> {
        let is_stop = !matches!(command, MountCommand::Move { .. });
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
                Event::Ack(id) => reports.push(MountReport::Acknowledged(id)),
                Event::Lost(why) => {
                    if !self.lost {
                        self.lost = true;
                        reports.push(MountReport::TransportLost);
                    }
                    self.notes.push(why);
                }
                Event::Position(p) => self.positions.push(p),
                Event::Note(n) => self.notes.push(n),
            }
        }
        reports
    }
}

impl Drop for CelestronAdapter {
    /// Closing the queue makes the worker stop both axes, then exit.
    fn drop(&mut self) {
        self.jobs = None;
        if let Some(worker) = self.worker.take() {
            let _ = worker.join();
        }
    }
}

struct Worker<L: Link> {
    link: L,
    signs: AxisSigns,
    clock: Clock,
    events: mpsc::Sender<Event>,
    timeouts: u32,
}

impl<L: Link> Worker<L> {
    fn run(mut self, jobs: mpsc::Receiver<MountCommand>, position_every: Option<Duration>) {
        loop {
            let first = match position_every {
                Some(every) => jobs.recv_timeout(every),
                None => jobs.recv().map_err(|_| RecvTimeoutError::Disconnected),
            };
            match first {
                Ok(command) => {
                    let mut batch = vec![command];
                    batch.extend(jobs.try_iter());
                    for command in overtake(batch) {
                        self.execute(&command);
                    }
                }
                Err(RecvTimeoutError::Timeout) => self.read_position(),
                Err(RecvTimeoutError::Disconnected) => {
                    self.execute(&MountCommand::StopAll);
                    return;
                }
            }
        }
    }

    fn execute(&mut self, command: &MountCommand) {
        let mut all_ok = true;
        for bytes in transactions(command, self.signs) {
            let (outcome, _) = transact(&mut self.link, &bytes, 0, true);
            all_ok &= outcome == Outcome::Ok;
            self.outcome(outcome, command);
        }
        if all_ok && let MountCommand::Move { id, .. } = command {
            let _ = self.events.send(Event::Ack(*id));
        }
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
                let _ = self
                    .events
                    .send(Event::Lost("the serial port failed".into()));
            }
        }
    }

    fn read_position(&mut self) {
        let query = Query::PreciseAzmAlt;
        let (outcome, reply) = transact(&mut self.link, &query.bytes(), query.reply_len(), false);
        if outcome == Outcome::Ok
            && let Some(Value::Angles {
                azm_deg, alt_deg, ..
            }) = query.decode(&reply[..query.reply_len()])
        {
            self.timeouts = 0;
            let _ = self.events.send(Event::Position(Position {
                t_ns: (self.clock)(),
                deg: [azm_deg, alt_deg],
            }));
        }
    }
}

/// A stop overtakes any move queued before it: once the controller has
/// asked for a stop, an older move must not start.
fn overtake(batch: Vec<MountCommand>) -> Vec<MountCommand> {
    let is_stop = |c: &MountCommand| !matches!(c, MountCommand::Move { .. });
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
