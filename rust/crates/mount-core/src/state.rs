//! The session state machine (ADR 0005). [`crate::Controller`] drives it;
//! every state change goes through [`transition`].
//!
//! ```text
//! DISCONNECTED → CONNECTED_READ_ONLY → ARMED → MOVING → STOPPING → ARMED
//!                      any state with a fault → FAULT_LATCHED
//!                      FAULT_LATCHED → CONNECTED_READ_ONLY   (manual reset only)
//! ```

use serde::Serialize;
use thiserror::Error;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum MountState {
    Disconnected,
    ConnectedReadOnly,
    Armed,
    Moving,
    Stopping,
    FaultLatched,
}

impl MountState {
    pub const ALL: [MountState; 6] = [
        MountState::Disconnected,
        MountState::ConnectedReadOnly,
        MountState::Armed,
        MountState::Moving,
        MountState::Stopping,
        MountState::FaultLatched,
    ];

    /// True in states where the mount may be in motion, so a fault there
    /// requires a stop to be issued.
    pub fn may_be_moving(self) -> bool {
        matches!(self, MountState::Moving | MountState::Stopping)
    }
}

/// Why a fault was latched. Every one of these stops motion.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum FaultKind {
    StaleImu,
    TransportLost,
    CommandTimeout,
    AcknowledgementMissing,
    UnexpectedMotion,
    OppositeMotion,
    /// The commanded axis did not start moving in time.
    Stall,
    /// The commanded axis turned faster than commanded.
    Overspeed,
    /// A goto went further past its target than the approach margin.
    Overshoot,
    /// A goto settled further from its target than the tolerance.
    MissedTarget,
    /// Motion continued past the stop deadline.
    StopNotObserved,
    LimitBreach,
    ProcessShutdown,
    EmergencyStop,
    /// An event arrived that the current state does not allow.
    InvalidTransition,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MountEvent {
    /// Read-only connection to the mount established.
    TransportConnected,
    /// Clean disconnect requested by the operator from a non-moving state.
    TransportClosed,
    /// Explicit operator action. Nothing else arms the session.
    OperatorArm,
    OperatorDisarm,
    /// A motion command passed every interlock and was transmitted.
    MotionCommandSent,
    /// A stop was requested (duration limit, operator, or end of trial).
    StopRequested,
    /// The IMU confirms motion has ended. Sending a stop is not enough.
    MotionEndedObserved,
    Fault(FaultKind),
    /// Explicit operator action after reviewing a fault.
    OperatorReset,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Error)]
#[error("event {event:?} is not allowed in state {state:?}")]
pub struct InvalidTransition {
    pub state: MountState,
    pub event: MountEvent,
}

/// Computes the next state. Pure function; callers must treat an error as a
/// fault (latch it and stop) rather than ignoring it.
pub fn transition(state: MountState, event: MountEvent) -> Result<MountState, InvalidTransition> {
    use MountEvent as E;
    use MountState as S;
    let next = match (state, event) {
        (_, E::Fault(_)) => S::FaultLatched,
        (S::Disconnected, E::TransportConnected) => S::ConnectedReadOnly,
        (S::ConnectedReadOnly, E::TransportClosed) => S::Disconnected,
        (S::ConnectedReadOnly, E::OperatorArm) => S::Armed,
        (S::Armed, E::OperatorDisarm) => S::ConnectedReadOnly,
        (S::Armed, E::MotionCommandSent) => S::Moving,
        (S::Moving, E::StopRequested) => S::Stopping,
        (S::Stopping, E::MotionEndedObserved) => S::Armed,
        (S::FaultLatched, E::OperatorReset) => S::ConnectedReadOnly,
        _ => return Err(InvalidTransition { state, event }),
    };
    Ok(next)
}

#[cfg(test)]
mod tests {
    use super::*;
    use MountEvent as E;
    use MountState as S;

    const EVENTS: [MountEvent; 10] = [
        E::TransportConnected,
        E::TransportClosed,
        E::OperatorArm,
        E::OperatorDisarm,
        E::MotionCommandSent,
        E::StopRequested,
        E::MotionEndedObserved,
        E::Fault(FaultKind::StaleImu),
        E::Fault(FaultKind::EmergencyStop),
        E::OperatorReset,
    ];

    #[test]
    fn documented_happy_path() {
        let mut s = S::Disconnected;
        for e in [
            E::TransportConnected,
            E::OperatorArm,
            E::MotionCommandSent,
            E::StopRequested,
            E::MotionEndedObserved,
            E::OperatorDisarm,
            E::TransportClosed,
        ] {
            s = transition(s, e).unwrap();
        }
        assert_eq!(s, S::Disconnected);
    }

    #[test]
    fn every_fault_latches_from_every_state() {
        for s in S::ALL {
            assert_eq!(
                transition(s, E::Fault(FaultKind::TransportLost)),
                Ok(S::FaultLatched)
            );
        }
    }

    #[test]
    fn only_operator_arm_enters_armed() {
        for s in S::ALL {
            for e in EVENTS {
                if transition(s, e) == Ok(S::Armed) {
                    assert!(
                        e == E::OperatorArm || (s == S::Stopping && e == E::MotionEndedObserved),
                        "{s:?} --{e:?}--> Armed"
                    );
                }
            }
        }
    }

    #[test]
    fn motion_only_starts_from_armed() {
        for s in S::ALL {
            for e in EVENTS {
                if transition(s, e) == Ok(S::Moving) {
                    assert_eq!((s, e), (S::Armed, E::MotionCommandSent));
                }
            }
        }
    }

    #[test]
    fn fault_latch_only_clears_by_operator_reset_and_never_rearms() {
        for e in EVENTS {
            match transition(S::FaultLatched, e) {
                Ok(S::FaultLatched) => assert!(matches!(e, E::Fault(_))),
                Ok(next) => {
                    assert_eq!(e, E::OperatorReset);
                    assert_eq!(next, S::ConnectedReadOnly);
                }
                Err(_) => {}
            }
        }
    }

    #[test]
    fn moving_cannot_be_left_without_a_stop_or_fault() {
        for e in EVENTS {
            if let Ok(next) = transition(S::Moving, e) {
                assert!(matches!(next, S::Stopping | S::FaultLatched), "{e:?}");
            }
        }
    }

    #[test]
    fn stop_is_complete_only_when_motion_end_is_observed() {
        assert_eq!(
            transition(S::Stopping, E::StopRequested),
            Err(InvalidTransition {
                state: S::Stopping,
                event: E::StopRequested
            })
        );
        assert_eq!(
            transition(S::Stopping, E::MotionEndedObserved),
            Ok(S::Armed)
        );
    }

    #[test]
    fn cannot_disconnect_cleanly_while_armed_or_moving() {
        for s in [S::Armed, S::Moving, S::Stopping] {
            assert!(transition(s, E::TransportClosed).is_err());
        }
    }
}
