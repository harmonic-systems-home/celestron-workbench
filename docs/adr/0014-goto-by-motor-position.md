# ADR 0014: Gotos by motor position

**Status:** Accepted

## Context

Every move so far is a timed slew: a variable rate, then a stop when the lease ends. Its travel is rate × time, so it carries the timing jitter between the Mac, the hand controller and the motors (about ±25 ms, ±0.003° at 0.1 °/s), slow position reads that delay a move (O7), and each axis's rate scale (altitude runs about 3% long, O10). The characterization trials need travel set by position instead, to measure backlash (O9) and to step and settle (ADR 0007).

The motor controllers answer the community-documented AUX command set. Discovery confirmed the two read-only commands this needs (ADR 0010, 2026-10-29): `MC_GET_POSITION` (`P 01 10|11 01 00 00 00 03`) returns each axis's position, 24 bits per revolution and identical to the hand controller's `z`; `MC_SLEW_DONE` (`P 01 10|11 13 00 00 00 01`) returns 0xFF when no goto is running. The same set has `MC_GOTO_FAST` (`0x02`) and `MC_GOTO_SLOW` (`0x17`), each with a 3-byte target: `P 04 10|11 02|17 HH MM LL 00`. Not yet known on these controllers: either goto's speed, acceleration and deceleration; whether they overshoot and come back; whether the motor controllers' anti-backlash applies to them; and whether our stop (`T 00`, then fixed rate 0) ends a goto in progress.

## Decision

### The command

- **`MountCommand::Goto { id, axis, target, speed }`**, with `target` in motor units (24 bits per revolution) and `speed` `Slow` or `Fast`. One axis at a time, as for moves.
- **Requests are relative:** `GotoRequest { request_id, axis, delta_deg, speed, approach }`. The controller takes the latest mount position, adds `delta_deg`, wraps to 24 bits, and sends that target. Operator syntax: `goto az +0.2`, `goto alt -0.5 fast`, `goto az +0.2 from-`.
- **The adapter** sends `P 04 dev 02|17 HH MM LL 00` and reports `Sent` and `Acknowledged` as for moves. While a goto runs it reads that axis's position and slew-done flag in turn, as fast as replies come (about every 90 ms), and reports both. Moves keep their rule of no reads between move and stop; a goto has no lease to protect, so reads during it cost nothing.
- **Done** is the goto-finished flag set and two position reads in a row agreeing, within `goto_tolerance_deg` of the target; then the controller sends the usual stop, and the IMU must show the axis still for `still_hold_ms` before the goto completes. The adapter's watch ends at the same point, and outlasts a stop so the record shows whether the stop ended the goto. The record keeps the start, target, legs, the position read before any stop and the last one, the error, the largest excursion past the target and how many times the axis crossed it, and the time to settle: overshoot is measured, not assumed away.

### Consistent approach is a flag, off by default

- **`approach: Option<Direction>`.** `None` (the default) sends one goto to the target. `Some(side)` ends every goto moving toward `side`: if the move already heads that way, one goto; if not, a first goto to the target plus `approach_margin_deg` on the far side, then a slow goto back to the target. One request, two motor commands, one record.
- **It overlaps with the mount's own compensation, so it isn't on by default.** Anti-backlash, set in the motor controllers, takes up slack on a reversal; the hand controller's own "GoTo Approach" menu setting does what this flag does, but only for the hand controller's gotos, not for gotos sent through to the motor controllers. Once anti-backlash values are chosen (O9), the flag stays off and the motor controllers do the work. The runner still refuses to start unless anti-backlash is 0, so the two can't both act yet; when that rule is relaxed, the flag must be refused or warned about while anti-backlash isn't 0.
- **The approach leg** is sent only once the first leg has finished and the IMU too shows the axis still, as for any request.
- **The margin** (`approach_margin_deg`, configured) must exceed the backlash: 0.15° covers the 0.068° measured in azimuth (O9) with room.

### Safety

The interlocks of ADR 0005 carry over, with changes for motion that has no constant commanded rate:

- **Limits checked before sending:** `max_goto_deg` per leg (configured, initially 0.05°: see Stop), every leg's altitude inside the envelope, and an approach leg within the same limits.
- **Speed:** a goto may not exceed `max_goto_rate_deg_s` (overspeed latches, as for moves). Its value comes from the first hardware trial; until then it is the move cap, 1 °/s, and fast gotos are refused (`allow_fast_goto = false`).
- **Direction:** motion opposite to the goto's direction latches `OppositeMotion`, except within `approach_margin_deg` of the target, where a servo correction may reverse briefly. That allowance is the only new exception and is itself measured (crossings and excursion are in the record). The axis positions add their own checks: running more than the margin the wrong way from where the leg started is `OppositeMotion`, more than the margin past the target is the new `Overshoot`, and settling further than `goto_tolerance_deg` (0.01°) from it is the new `MissedTarget`.
- **The other axis** moving latches `UnexpectedMotion`, as for moves.
- **Deadline:** each leg must settle within `distance / min_goto_rate_deg_s + goto_settle_ms` (0.05 °/s and 2 s to start with) of leaving. Missing it latches `CommandTimeout` and stops. A stalled axis isn't moving, so a long deadline is harmless.
- **Travel:** commanded travel for the tally is the target minus the start, so the accumulated travel checks still apply.
- **Stop:** Enter, faults and quitting send the same stop as for moves. Whether that ends a goto is the first thing the hardware trial checks (below); until it is shown, gotos are capped at a distance that ends within about 1 s at the slow speed, so an unstoppable goto still ends on its own almost at once.

### Order of work

1. **Simulator:** `SimMount` gains gotos with configurable speed, acceleration, overshoot and "stop doesn't cancel a goto" faults. `SimHandController` decodes the goto bytes. Safety tests cover a clean goto, overshoot within and beyond the allowance, a goto that never finishes, one that runs fast, one the stop can't cancel, and an approach-flag goto with its two legs.
2. **Runner:** the `goto` command, records and log, refusing fast gotos until `max_goto_rate_deg_s` is set from a trial.
3. **First hardware goto:** azimuth, slow, 300 units (about 23″), anti-backlash 0, operator at the power switch. It measures speed, profile, overshoot and settle from the 90 ms reads.
4. **Stop during a goto:** a slow azimuth goto long enough to stop halfway, to check that the stop ends it. Only after this pass do gotos get longer than the 1 s cap.
5. **Fast gotos** once their speed is measured, then the approach flag, then the backlash trials of O9 by position.

## Consequences

- Travel no longer depends on timing or rate scale; it depends on how well the servos hold position, which these trials measure.
- The adapter gains its first commands that set a target position. The catalog test grows to allow exactly `0x02` and `0x17` with a 3-byte target, nothing else.
- Overshoot, if any, is recorded rather than hidden, and the opposite-motion check gets a narrow, measured exception near the target.
- Consistent approach is available for trials without anti-backlash and stays off once anti-backlash is configured, so the two don't compound.
- Until the stop-during-goto trial passes, gotos are limited to about 1 s of travel.

## First hardware gotos (2026-10-30)

- **Steps 3 and 4 ran** (docs/observations.md, O11). Slow gotos run at about 0.29 °/s, end within ±1 unit and settle in under a second. Our stop (tracking off, then fixed rate 0) does **not** end a goto: the axis carried on to its target.
- **Change:** after a stop, an axis whose goto is still running (its finished flag not yet read done) is read once and sent a slow goto to that position, so it stops about there with a short reversal. The adapter does this for both a stop and a stop-all; the simulated hand controller now ignores tracking off and fixed rate 0 during a goto, as the mount does, so the adapter tests exercise the re-aim. `max_goto_deg` stays 0.05° until a repeat of step 4 shows the re-aim ends a goto.
- **Repeat of step 4 (same day):** the re-aim now goes before tracking off and fixed rate 0, which take about 100 ms and do nothing to a goto. With slow gotos measured at about 0.5 °/s over 0.2°, `max_goto_deg` went to 0.2° (about 0.6 s, so still about 1 s of travel). A slow 0.199° goto stopped a third of the way ended 0.062° past the point where the stop was sent and 0.039° short of its target (O11): the re-aim ends a goto. The cap can now follow the trials' needs rather than the stop's; fast gotos still wait for their speed to be measured.
