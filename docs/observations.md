# Observations

Mount and software behaviour worth explaining, one entry per symptom. Each entry records what was seen, the sequence that produces it (or "not yet reproduced"), the evidence, and where it stands. The goal is a minimal sequence for every problem: one change at a time, each step a command with a log.

Evidence paths are run logs and discovery reports under `reports/` (git-ignored, on the operator's Mac). Times are local (Pacific); log names are UTC.

**Status:** *open* (seen, cause unknown), *reproduced* (a sequence produces it), *explained* (cause known), *fixed* or *worked around*.

## O1. Slow creep on both axes, with audible motor stepping

- **Seen:** 2026-10-29. Both axes turned at about 0.2″/s (0.8° an hour), the same on each; the altitude motor stepped audibly every second or two. Tracking read off, no goto, anti-backlash 0.
- **Sequence so far:** none at 12:22–12:28 (discovery). Present at 14:40, in position reads before this software's first motion command. In between, the tube was raised with the hand controller's arrow keys. Stop commands on quitting didn't end it; a mount power cycle did.
- **Evidence:** discovery `2026-10-29T19-28-19` (still) and `2026-10-29T22-24-53` (creeping); run log `2026-10-29T21-40-59` (creeping before the first move); run log `2026-10-29T22-22-00`.
- **Next:** power on, discovery (expect still); one short arrow press; discovery again. If it creeps, repeat, then vary the press length, rate and axis.
- **Status:** open. The runner now latches unexpected motion if the mount's own positions drift while armed and idle (ADR 0013).

## O2. Hand controller's USB serial port can't be opened after the hand controller restarts

- **Seen:** 2026-10-29, twice (once from an unexplained restart around 15:03, once from a deliberate power cycle). The device stays listed but opening it fails ("Invalid argument") until the cable is unplugged at the hand controller and plugged back in. The cable goes directly into the Mac.
- **Unknown:** whether the ASIAIR is affected the same way, and whether waiting longer is enough.
- **Status:** worked around. The tools beep, ask for a re-plug and wait; the runner reconnects mid-session (ADR 0013).

## O3. iOS's fused rotation rate hides slow steady rotation

- **Seen:** 2026-10-29, first hardware move. During a 0.1 °/s move the fused rate faded to zero within about 1 s and read −0.08 °/s after the stop; the raw gyroscope showed the true rate.
- **Status:** explained (iOS's bias estimator) and fixed: safety checks use the raw gyroscope with an offset measured at arming (ADR 0013).

## O4. A stop delayed behind a position read

- **Seen:** 2026-10-29, second move. The stop reached the serial port 208 ms late, queued behind a position read, which the hand controller answers slowly while a motor slews.
- **Status:** fixed: no position reads between a move and its stop (ADR 0013).

## O5. Phone app stuck at "Connecting (attempt 1)"

- **Seen:** 2026-10-29, when the Mac's receiver was restarted during a recording.
- **Status:** fixed: the app retries a connection that isn't ready within 5 s.

## From earlier use (not yet reproduced)

Problems from about two years ago, before this project, without a known sequence. To be pinned down one at a time once basic motion is characterized; fill in details as they come back.

- **H1. ASIAIR:** problems controlling or connecting to the mount (details to add).
- **H2. StarSense self-calibration:** problems with auto-alignment or calibration (details to add).
- **H3. Tracking:** problems with tracking (details to add). O1's creep is a candidate for some of these.
- **H4. Hand controller arrow keys:** unexpected behaviour of arrow-key moves (details to add). O1 may be one.
