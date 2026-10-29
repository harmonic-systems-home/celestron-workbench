# ADR 0005: Mount safety state machine and interlocks

**Status:** Accepted

## Context

This software will eventually send motion commands to a real telescope mount. "Safety" here means machine safety: keeping the telescope from damaging itself. The mount moves slowly (this software commands at most 1 °/s), so it is no hazard to people. The harm to prevent is mechanical: the tube or anything on it (camera, phone, dew heater) hitting the tripod or the mount base, cables snagging or wrapping, the phone being knocked off, or an axis driven against a hard stop. All of these come from travel going further than intended, so the interlocks bound how far the mount can move unchecked rather than how fast. The software is not the primary safety system; the operator and the mount's power switch are.

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

Code that can move real hardware lives only in `mount-celestron` (ADR 0013). It was created after:

1. the simulator (`mount-sim`) passes the fault-injection suite (stop, timeout, stale data, duplicate command, opposite motion, connection loss, ignored stop, process shutdown), and
2. a read-only discovery tool has produced a protocol compatibility report for the exact mount and firmware, reviewed by the operator.

## Consequences

- `mount-core` must stay free of I/O so the state machine can be tested exhaustively.
- Hardware tests start with one axis, the lowest useful rate and the shortest practical pulse, with someone watching the mount for clearance and cable snags.

## Implementation (plan Prompt 6)

`mount-core` holds the [`Controller`](../../rust/crates/mount-core/src/controller.rs): pure, with every input stamped with Mac time and every output an action to carry out at once (send a command, alert the operator). `mount-sim` holds a deterministic two-axis mount and IMU with fault injection, and a harness that wires them together the way the hardware runner will. The safety suite is `cargo test -p cwb-mount-sim`.

- **Inputs:** operator actions (connect, arm, disarm, move, stop, emergency stop, reset), mount acknowledgements, link loss, IMU observations already in mount-axis terms (azimuth and altitude rates, tube altitude, on the Mac clock), process shutdown, and a periodic tick for deadlines.
- **A move request** names one axis, a direction, a rate and a duration. It is recorded first, then refused unless the session is armed, no command is active, the request ID is new (a duplicate is refused, never re-sent), the rate and duration are within the configuration, the IMU is fresh, the altitude is inside the envelope, and both axes are still. The duration is the command's lease: when it ends, the controller sends the stop.
- **During motion** the controller latches a fault and sends `StopAll` on: no acknowledgement by the deadline; stale IMU; the commanded axis moving opposite to the command; moving faster than commanded (overspeed); the other axis moving; leaving the altitude envelope; motion continuing past the stop deadline. Rates are averaged over a short window before every check.
- **Completion** needs both axes still for a hold time. A single command need not be seen: a small or slow step may be below what the IMU resolves in one move.
- **Accumulated travel** replaces a per-command "was it seen" check. For each axis the controller tallies net commanded travel (rate × time to stop, signed) and observed travel (IMU rate integrated continuously while armed). When the commanded tally reaches `verify_travel_deg` (1°), the observed tally must have reached `min_observed_fraction` (half) of it in the same direction: then both reset; if not, the session latches a stall, or opposite motion if it went the other way. So ten steps the IMU can't see one by one are fine, but the commanded position never strays more than 1° from the last confirmed one. Back-and-forth steps (ADR 0007) cancel in the net tally; gear backlash shows up as a shortfall after a reversal and must stay well under half of `verify_travel_deg`.
- **Travel beyond commanded:** an axis whose observed tally exceeds its commanded travel (including the active command so far) by `travel_tolerance_deg` (0.25°) latches unexpected motion and tells the operator to cut power if it is still moving. This catches motion too slow for the rate checks, above all a slow move whose stop was ignored, which the still threshold would otherwise accept as stopped.
- **While armed with no command**, any motion, travel beyond commanded, or a stale IMU latches a fault.
- **While latched**, `StopAll` is re-sent at intervals until the IMU confirms both axes still: rates below the still threshold for the hold time, and no creep beyond the tolerance since the rates first fell still. Each re-send tells the operator to cut mount power: because motion is seen, or because a silent IMU means the stop can't be confirmed. A failed re-send over a lost link does not stack further faults.
- **Reset** is refused until the IMU is fresh and shows the mount still; it returns to read-only, and arming is a separate operator action.
- **Configuration** ([`SafetyConfig`](../../rust/crates/mount-core/src/config.rs)) is checked before use. It refuses settings that blind an interlock: non-positive rates, thresholds or travel limits, an observed fraction outside (0, 1], a still threshold at or above the motion threshold, an empty altitude envelope. Defaults: 0.001–1.0 °/s, at most 2 s per command, acknowledgement within 300 ms, still within 1.5 s of a stop, IMU at most 1 s old, confirmation every 1° of net commanded travel, 0.25° travel tolerance.

**Proven in simulation:** delayed and missing acknowledgements, an ignored stop, opposite motion, stall (of one large move and of a run of small unseen steps), slow wrong-way motion below the rate threshold, a slow creep after an ignored stop, overspeed, a dropped link with the axes still turning, a silent IMU, a duplicate request, process shutdown, emergency stop, an external bump while armed, leaving the altitude envelope, refused requests, and manual re-arming. A randomized search over 1,000 fault combinations checks that every fault stops first, motion is only commanded when armed, commands never overlap and always reach a final stage, a stoppable mount always ends still, and an unstoppable one always gets the cut-power alert. That search found two gaps, both fixed: an ignored stop with a silent IMU gave no alert; and, once slow moves were allowed, a slow move whose stop was ignored crept on below the still threshold unnoticed (fixed by the travel-beyond-commanded check).

**Known limits for the hardware stage:**

- The software cannot stop a mount that ignores stops or keeps turning after its link drops; it can only latch and keep alerting. The operator's power switch (layer 1) remains the real stop.
- A mount that goes wrong slowly is caught by travel, not rate, so it can move up to the tolerance (0.25°) beyond commanded, or 1° of commanded travel unconfirmed, before the latch. Both are harmless indoors; tighten them once the hardware's behaviour is known.
- Observed travel is integrated gyro rate, so gyro bias accumulates while armed: a bias of b °/s trips the travel check after 0.25/b seconds idle. Disarm during long holds (ADR 0007). The 30-minute still recording measures b.
- The IMU freshness limit (1 s) is close to the Wi-Fi delivery delays measured so far (99th percentile 0.93 s, worst 1.1 s, docs/assumptions.md N1). Expect false stale-IMU faults over Wi-Fi until the phone sends smaller, more frequent batches or the link improves; the limit is not to be raised to hide them.
- Observations must be in mount-axis terms. Mapping the phone's attitude onto the azimuth and altitude axes belongs to the hardware runner (plan Prompt 8).
