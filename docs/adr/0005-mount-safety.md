# ADR 0005: Mount safety state machine and interlocks

**Status:** Accepted

## Context

This software will eventually send motion commands to a real telescope mount. A runaway or unstoppable mount can damage equipment or injure someone. The software is not the primary safety system; the operator and the mount's power switch are.

## Decision

### Layers, outermost first

1. **Operator and power.** The operator stays within reach of the mount's power switch or another proven stop that works with the Mac process dead. This is checked by hand at the start of every mount session.
2. **Mount firmware limits.** Celestron's own slew limits are never bypassed or modified.
3. **This software's interlocks**, described below.

### State machine

```text
DISCONNECTED → CONNECTED_READ_ONLY → ARMED → MOVING → STOPPING → ARMED
                     any state with a fault → FAULT_LATCHED
                     FAULT_LATCHED → CONNECTED_READ_ONLY   (manual reset only)
```

- Only an explicit operator action moves `CONNECTED_READ_ONLY → ARMED`. A phone connecting never arms anything.
- Any of these issues a stop through the safest available path and latches a fault: stale IMU stream, lost mount transport, command timeout, missing acknowledgement, unexpected motion, motion opposite to the request, limit breach, process shutdown, emergency stop.
- Re-arming after a fault is manual.
- A stop is "successful" only when the IMU shows motion has ended, not when the stop command was sent.

### Command rules

- One command lease at a time; one axis, one direction.
- Rate and duration are capped by a safety configuration fixed before the session and stored with it.
- Commands are rejected unless: IMU data is fresh, mount transport is healthy, the previous command has finished, and the session is armed.
- **Goto, slew-to-coordinates, and any command that starts open-ended motion are not implemented.** Unattended operation is out of scope.
- Every command is recorded before it is transmitted. Its lifecycle is `requested → transmitted → acknowledged → completed`, or ends in `cancelled`, `timed_out`, `rejected` or `unknown`. No command stays silently active.

### Hardware gate

Code that can move real hardware lives only in `mount-celestron`, which does not exist yet. It is created after:

1. the simulator (`mount-sim`) passes the fault-injection suite (stop, timeout, stale data, duplicate command, opposite motion, connection loss, ignored stop, process shutdown), and
2. a read-only discovery tool has produced a protocol compatibility report for the exact mount and firmware, reviewed by the operator.

## Consequences

- `mount-core` must stay free of I/O so the state machine can be tested exhaustively.
- Hardware tests start with one axis, the lowest useful rate and the shortest practical pulse, with a spotter.
