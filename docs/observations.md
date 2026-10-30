# Observations

Mount and software behaviour worth explaining, one entry per symptom. Each entry records what was seen, the sequence that produces it (or "not yet reproduced"), the evidence, and where it stands. The goal is a minimal sequence for every problem: one change at a time, each step a command with a log.

Evidence paths are run logs and discovery reports under `reports/` (git-ignored, on the operator's Mac). Times are local (Pacific); log names are UTC.

**Status:** *open* (seen, cause unknown), *reproduced* (a sequence produces it), *explained* (cause known), *fixed* or *worked around*.

## O1. Slow creep on both axes, with audible motor stepping

- **Seen:** 2026-10-29. Both axes turned at about 0.2″/s (0.8° an hour), the same on each; the altitude motor stepped audibly every second or two. Tracking read off, no goto, anti-backlash 0.
- **Sequence so far:** none at 12:22–12:28 (discovery). Present at 14:40, in position reads before this software's first motion command. In between, the tube was raised with the hand controller's arrow keys. Stop commands on quitting didn't end it; a mount power cycle did.
- **Evidence:** discovery `2026-10-29T19-28-19` (still) and `2026-10-29T22-24-53` (creeping); run log `2026-10-29T21-40-59` (creeping before the first move); run log `2026-10-29T22-22-00`.
- **Also in between:** at 12:44–12:46 the hand controller's time and location were set over USB (`cwb celestron setup`).
- **Tried:** after a power cycle, still (discovery `2026-10-29T22-53-30`); one 0.5 s altitude-up arrow press at the default rate (2.765°); still afterwards (`2026-10-29T22-56-35`). A short arrow press alone doesn't start it.
- **Tried:** time and location set over USB, then discovery twice about 44 s apart: still, identical positions (`2026-10-29T22-58-10`, `2026-10-29T22-58-54`). Setting time and location alone doesn't start it.
- **Tried:** a 23.4° altitude raise with the up arrow (several seconds): still afterwards (`2026-10-29T23-06-08`, `2026-10-29T23-07-01`). Arrow slews don't start it.
- **Found:** the 14:40 run's log shows azimuth at exactly 0.0000° at 14:39:37, unmoved since power-on, and creeping at 0.21″/s by 14:41; counting back puts the start at 14:39:38, when the first runner exited with a port error. Exiting drops the adapter, which sends `StopAll` (variable rate 0, then fixed rate 0, positive direction byte, both axes) to the still mount. In the second trial, altitude (never commanded) was still until the `StopAll` on quitting, and creeping by the next run.
- **Reproduced:** from still (`2026-10-29T23-07-01`), `cwb mount run`, `yes`, `quit` (no arm, no move): `StopAll` six times during the wind-down (run log `2026-10-29T23-09-07`). Then azimuth +0.215″/s and altitude creeping (`2026-10-29T23-09-23`), both +0.208″/s a minute later (`2026-10-29T23-10-04`).
- **Cause found (`cwb celestron stop-test`, one command to still azimuth, power cycle between creeps):**
  - fixed rate 0 positive (`P 02 10 24 00 00 00 00`): still (`reports/stop-test/2026-10-29T23-29-02…_fixed+_azm.json`).
  - variable rate 0 positive (`P 03 10 06 00 00 00 00`): creep +0.210″/s (`…23-30-11…_variable+_azm.json`).
  - variable rate 0 negative (`P 03 10 07 00 00 00 00`): creep −0.358″/s (`…23-31-48…_variable-_azm.json`).
  - On these motor controllers (7.17) a variable-rate command with rate 0 means "the slowest variable rate in that direction", not stop; the two directions run at different speeds. `StopAll` sent variable 0 and then fixed 0 and still left both axes creeping, so fixed 0 doesn't seem to cancel it.
- **Cancel found (`cwb celestron cancel-sweep`, `reports/stop-test/2026-10-29T23-40-59…_cancel-sweep.json`):** from still, variable rate 0 started a +0.212″/s azimuth creep. Fixed rate 0 positive, then fixed rate 0 negative: still creeping (+0.210″/s). **`T 00` (tracking off): still.** This fits variable-rate commands setting the motor controllers' guide/tracking rate, which fixed-rate commands don't touch and the hand controller's tracking off resets.
- **Confirmed on a real move (run log `2026-10-30T00-06-19`):** `az+ 0.1 1` stopped with `T 00` (answered in 66 ms) then fixed rate 0. The mount's own position went 0.00000° → 0.10001° (0.1003° commanded) and stayed exactly there for the next 60 s; the idle-creep check never fired.
- **Status:** fixed. Stops are `T 00` then fixed rate 0; variable rate 0 is never sent (ADR 0013). The runner now latches unexpected motion if the mount's own positions drift while armed and idle (ADR 0013).

## O2. Hand controller's USB serial port can't be opened after the hand controller restarts

- **Seen:** 2026-10-29, twice (once from an unexplained restart around 15:03, once from a deliberate power cycle). The device stays listed but opening it fails ("Invalid argument") until the cable is unplugged at the hand controller and plugged back in. The cable goes directly into the Mac.
- **Not every time:** after a third power cycle the same day, the port opened cleanly with no re-plug.
- **Unknown:** what distinguishes the failures (timing of the power cycle, whether the port was open, how long after start-up it was opened), whether the ASIAIR is affected the same way, and whether waiting longer is enough.
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

## O6. Stale-IMU fault while the phone was streaming normally

- **Seen:** 2026-10-29, 18:38. `status` showed the IMU "fresh" at −6119 ms (from the future) with the clock at ±26 s; 8 s after `arm`, with no move sent, the runner latched `StaleImu`. The phone sent about 300 samples a second throughout.
- **Sequence:** the phone kept recording in one session for 1.5 hours across two runner runs. When it reconnected to the new runner it resent about 70 s of backlog, and its clock pings, stamped when sent, waited behind it: 15 exchanges with round trips of 1–54 s against 5 ms for good ones. With most exchanges bad, the fit's median cut kept bad ones (offset seconds out). When the span of kept exchanges reached 30 s the fit solved for a drift of −39 %, moving fresh samples from 6 s ahead to 3 s behind: stale.
- **Evidence:** run log `2026-10-30T01-37-21`; session `f9ba0dec`'s exchanges 19–41 in the database. Replaying them through the fit reproduces the status line's −6119 ms and ±26402 ms exactly.
- **Status:** fixed. The fit drops exchanges more than 250 ms slower than the fastest (on the replay, right to 0.4 ms from the first prompt exchange); arming needs the clock known to ±100 ms; samples more than 1 s ahead aren't fresh; and the phone app holds clock pings after a reconnect until the resent backlog is acknowledged, starting anyway after 60 s (ADR 0013).

## From earlier use (not yet reproduced)

Problems from about two years ago, before this project, without a known sequence. To be pinned down one at a time once basic motion is characterized; fill in details as they come back.

- **H1. ASIAIR:** problems controlling or connecting to the mount (details to add).
- **H2. StarSense self-calibration:** problems with auto-alignment or calibration (details to add).
- **H3. Tracking:** problems with tracking (details to add). O1's creep is a candidate for some of these.
- **H4. Hand controller arrow keys:** unexpected behaviour of arrow-key moves (details to add). O1 may be one.
