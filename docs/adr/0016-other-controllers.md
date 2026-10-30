# ADR 0016: Other controllers on the mount

**Status:** Accepted

## Context

The runner assumes it is the only thing moving the mount. In use it won't be: the hand controller's arrow keys, SkySafari (through the Evolution's own Wi-Fi) and ASIAIR all command the same motor controllers over the AUX bus, and our commands reach the bus through the hand controller's pass-through.

The operator's main question is whether several controllers at once can **lock up the hand controller or make move commands stop working**. Before this project, nights went: StarSense alignment, then ASIAIR, then the USB link hung or moves stopped, forcing a mount power cycle that lost the alignment (observations H1–H4). ASIAIR was connected through the hand controller's USB port, the one the Mac uses now, so the runner stands where ASIAIR stood on that link; SkySafari may have been connected over the mount's Wi-Fi at the same time, so ladder step 5 (below) is the closest reproduction. After a power cycle the hand controller's USB port can't be opened until the cable is re-plugged. The hand controller also stalls on its own: every few seconds one exchange with it takes 0.5–1 s longer than usual (O7), cause unknown. A busy bus is one candidate.

What we know and don't:

- **No ownership on the bus.** As the community documents describe it (references.md), the AUX bus has a shared busy line so two senders don't garble one message; nothing stops two controllers commanding the same axis, and the last command wins. Not yet checked on this mount.
- **We see effects, not commands.** SkySafari's commands go from the Wi-Fi module onto the bus; the hand controller doesn't pass them back to us. We see other controllers through the encoders, the phone, and how long our own exchanges take. Listening to the bus needs hardware on an AUX port (the sensor-board idea), out of scope here.
- **Every exchange is already logged** with its send and reply times (the run log's `serial` events), so latency, stalls, timeouts and bad replies can be counted after the fact.
- **Detection of foreign motion exists:** while armed, motion no command explains latches `UnexpectedMotion` and sends a stop. While disarmed, nothing is checked.
- **Stopping a foreign goto doesn't:** our stop (tracking off, fixed rate 0) doesn't end a goto (O11). The adapter re-aims only a goto it sent. A goto from SkySafari or the hand controller can't be stopped from the Mac.
- **Prompt 10** asks for exclusive control ownership between this service and ASIAIR. Over this bus that can be a procedure and a check, not a lock.

## Decision

### First question: does contention break the hand controller or the moves?

Most of this needs no motion from us: the runner stays **disarmed**, reading positions on its usual schedule, while the operator uses the keypad and SkySafari. Our side is then read-only and adds no safety risk; we watch for symptoms.

**Symptoms, and how each is recorded:**

| Symptom | Recorded by |
|---|---|
| Exchanges slow down (stalls longer or more often than O7's baseline) | `serial` events: latency distribution per minute |
| Exchanges time out, or replies are short or malformed | `serial` events: counts per minute |
| The USB port vanishes or stops answering | Runner: port errors logged with time; the runner keeps trying to reopen and logs when it can |
| A move command is accepted but nothing moves | Our moves: acknowledgement without encoder change is recorded as `NoMotion`. Keypad and SkySafari: the operator types `note key did nothing` or `note skysafari slew ignored` |
| The hand controller's display or keypad freezes | The operator's `note` |
| SkySafari loses its connection | The operator's `note` |

**Load ladder**, each step about 10 minutes, with the phone recording alongside. Stop climbing at the first symptom and work out what recovers it:

1. **Baseline:** hand controller alone, our idle reads (O7's numbers, repeated today).
2. **SkySafari connected and idle:** it likely polls the mount's position continually to draw the scope's marker (not yet measured).
3. **SkySafari slews and arrow buttons**, short ones near the start position.
4. **Keypad presses** on the hand controller, rates up to 5.
5. **All at once:** SkySafari moving, keypad presses, our reads.
6. **Our reads faster, then ASIAIR-like traffic:** first a shorter read interval, to see whether the pass-through's load matters; then, still read-only plus guide-sized pulses, the pattern a Celestron driver sends through the hand controller port (frequent pointing queries, and guide pulses as keypad-rate moves, references.md). ASIAIR's own driver isn't public; INDI's Celestron driver is a stand-in, and the pattern is configurable so it can be corrected if ASIAIR's traffic is ever captured.
7. **Our moves too:** with the runner armed, rows 3, 4 and 8 of the matrix below.
8. **Soak:** 30–60 minutes at the step that came closest to failing, the operator moving the mount now and then.

**Recovery, least drastic first.** If something locks up: wait 30 s; close SkySafari; quit the runner (closing the port); unplug and re-plug the USB cable; reset the hand controller; power-cycle the mount. Each step and its result goes in the log (`note`), and positions are read before any power cycle if the link still answers. What clears it says where the fault lives: the USB bridge, the hand controller, or the bus.

**Later, with ASIAIR:** ASIAIR and the Mac can't share the hand controller's USB port, so ASIAIR itself is tested by plugging it in as it was on the nights the hangs happened, with SkySafari and the keypad as the other controllers, and the operator's `note`s (typed on the Mac, which then only records the phone) as the record. Until then, step 6's stand-in traffic is the nearest reproduction.

### Stop ends any goto

- **On every stop the adapter asks each stopped axis whether a goto is running** (`MC_SLEW_DONE`), whoever started it, and re-aims any that is at its current position, before tracking off and fixed rate 0. Its own watched goto keeps the current path. This adds two short exchanges (about 80 ms) per axis to a stop; the re-sent stops while a fault is latched (every 250 ms) ask again only while motion continues, so they don't starve the position reads.
- **Records name the likely source:** encoders moving with a goto running is "a goto we didn't send (SkySafari or the hand controller)"; moving without one is "a fixed-rate or tracking move we didn't send (the arrow keys?)".

### Watching while disarmed

- **The runner keeps reading positions while disarmed** (it already does) and records foreign motion as an observation, not a fault: start, end, travel from the encoders and the phone, speed profile, and whether a goto was running. That makes "the same move from SkySafari and from us" comparable: we can't see SkySafari's command, but we can measure what it did.
- **Link health:** `status` shows, and the log records each minute, the exchanges, their latency (median, 95th percentile, longest), stalls over 400 ms, timeouts and bad replies.
- **Ownership by procedure:** armed means the runner owns the mount and the operator keeps hands off the keypad and SkySafari; anything else moving is a fault and is stopped. Disarmed means others may move it and the runner only watches. The checklist says so; the runner prints it when arming.

### Collision matrix

Simulator first: `SimMount` gains a second controller that can start fixed-rate moves and gotos at chosen times, and the hand controller fake answers slew-done for them. Then on hardware, small motions only (keypad rates up to 5, SkySafari slews of a few degrees at most), operator at the power switch:

| # | Situation | Expect | Question |
|---|---|---|---|
| 1 | Arrow key, runner disarmed | Recorded, not stopped | Rate and take-up match our keypad moves (O16)? |
| 2 | Arrow key held, runner armed and idle | `UnexpectedMotion`, stop | Does our stop override a held key? Does the key work again afterwards? |
| 3 | Arrow key during our move | Fault or overspeed, stop | Which command wins? Do later moves still work? |
| 4 | Our move while a key is held | Refused or faults | Same |
| 5 | SkySafari slew, runner disarmed | Recorded | Its speed profile and settling against our gotos |
| 6 | SkySafari slew, runner armed | `UnexpectedMotion`; the stop ends the goto | Does the re-aim stop a goto we didn't send? Does SkySafari recover? |
| 7 | SkySafari's arrow buttons, runner disarmed | Recorded | Fixed-rate (keypad-like) or variable-rate moves? |
| 8 | Our goto during a SkySafari slew | Fault, stop | Same as 6 |

After every row, a short check that each controller can still move the mount (one keypad press, one SkySafari nudge, one of our moves): that catches "moves stop working" even when nothing else looks wrong.

### Order of work

1. **Runner:** link-health summaries, port loss and reopen logging, `NoMotion` records, disarmed watching. Simulator tests for each.
2. **Hardware, read-only:** ladder steps 1–6 and matrix rows 1, 5 and 7. No motion from us.
3. **Stop ends any goto,** with the simulator's second controller and tests; then rows 2 and 6 on hardware.
4. **Ladder step 7** and rows 3, 4 and 8; then the soak.

## Consequences

- The night failures get a controlled reproduction attempt, mostly with our side read-only, and a record of what recovers each symptom.
- A goto from any controller can be stopped from the Mac, which narrows the one gap where only the power switch helped.
- Each stop costs about 80 ms more per axis; the stop deadline (1.5 s) has room.
- Ownership stays a procedure: the runner can detect and stop another controller, not prevent it.
- SkySafari's and the keypad's moves become measurable alongside ours, which feeds the Phase 2 report and later the ASIAIR work (Prompt 10).
- If contention isn't the cause, the ladder rules it out, which points the search elsewhere: the USB bridge, power, cables or ASIAIR's own behaviour.
