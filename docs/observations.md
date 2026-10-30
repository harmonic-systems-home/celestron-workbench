# Observations

Mount and software behaviour worth explaining, one entry per symptom. Each entry records what was seen, the sequence that produces it (or "not yet reproduced"), the evidence, and where it stands. The goal is a minimal sequence for every problem: one change at a time, each step a command with a log.

Evidence paths are run logs and discovery reports under `reports/` (git-ignored, on the operator's Mac). Times are local (Pacific); log names are UTC.

Outside sources (Celestron, the community AUX command set, forums) are listed in [references.md](references.md).

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

## O7. Some position reads take about 600 ms

- **Seen:** 2026-10-29, in all three runner logs that evening. Position reads normally come every ~310 ms (a 250 ms pause plus a ~60 ms answer); about every 3.2 s the gap is 840 ms, so one answer takes ~600 ms. They aren't timeouts (those are 3.5 s) and the reply is good. Occasionally longer gaps (1.3–1.7 s) coincide with moves.
- **Effect:** a command handed over during a slow read waits for it. One move went out 63 ms late (run log `2026-10-30T02-03-33`); another wasn't sent within the then 300 ms acknowledgement deadline, which latched with nothing moved (`2026-10-30T02-12-03`).
- **Unknown:** what the hand controller is doing every 3.2 s (display, StarSense camera, motor polling?), and whether other commands are slow at the same moments.
- **Status:** worked around: a move's lease and acknowledgement deadline run from when it actually leaves, with a separate send deadline (ADR 0013), now 2.5 s after a read of about 1 s held a goto past 1 s (O14).
- **2026-10-30:** idle positions are now read from the motor controllers (`P 01 10|11 01`) instead of `z`. The usual gap fell from about 340 to 260 ms, but the stalls remain: every few seconds a read takes 0.5 or 1 s more (gaps of 760 or 1,260 ms then 80 ms). Pass-through goes through the hand controller too, so the stall is the hand controller's, not `z`'s.

## O8. Axis positions back at 0 between sessions, without a power cycle

- **Seen:** 2026-10-29, twice. Run log `2026-10-30T02-03-33` ended at azimuth 0.1990°, altitude 0.0970°; the next session (`2026-10-30T02-12-03`, 7 minutes later) started at exactly 0.0000°, 0.0000°. Run log `2026-10-30T02-40-58` ended at azimuth −93, altitude −46 units (359.9980°, 359.9990°); discovery 15 minutes later (`2026-10-30T02-58-00`) read −1 and +1 units. Both times both axes went back to the power-on position, and nothing of ours touched the port in between. No power cycle, and nothing else connected to the mount.
- **Not reproduced (same evening):** positions held through a 15-minute continuous watch after a runner session (`2026-10-30T03-22-24`); 10 minutes with the port closed (`03-32-55`); a runner session then 15 minutes with the port untouched (`03-49-21`); an altitude move, then a 5-minute watch a minute later (`03-56-46`), then 15 minutes untouched (`04-12-02`). Both resets had followed a session that moved altitude; the repeat with an altitude move didn't reset.
- **Unknown:** whether the mount drove back (a goto to 0) or only the counters were reset; no receiver was running during either gap, so there is no phone data. Whether anyone touched the hand controller then.
- **Status:** open. Until explained, every session should compare its starting positions with where the last one ended.

## O9. Lost motion on reversal (gear backlash), anti-backlash 0

- **Seen:** 2026-10-29. On a reversal the motor encoder turns the commanded amount but the tube turns less. Measured with the mount's positions (motor side) against the phone's raw gyroscope (tube side), integrated through each move and 3 s of settling, with the gyroscope's offset taken from the 2.8 s of stillness just before each move.
- **Trial** (run log `2026-10-30T04-55-22`, phone session `e7bb941e`): per axis, six 0.2° moves at 0.2 °/s, `+ + − − + +`, 7 s apart.

  | Move | Azimuth: tube − encoder | Altitude: tube − encoder |
  |---|---|---|
  | + | −0.001° | −0.021° |
  | + | +0.007° | +0.006° |
  | − (reversal) | **+0.070°** | **+0.008°** |
  | − | +0.020° | −0.004° |
  | + (reversal) | **−0.065°** | **−0.037°** |
  | + | −0.003° | +0.018° |

- **Azimuth:** about 0.068° (245″, about 3,200 encoder units) each way, consistent with the 0.1° trial earlier (0.072°, run log `2026-10-30T02-40-58`). Moves without a reversal agree to about ±0.01°.
- **Altitude:** 0.008° down after up, 0.037° up after down, against ±0.02° scatter without a reversal: small, possibly asymmetric, not yet resolved. The tube's weight likely keeps the altitude gears loaded on one side.
- **Status:** measured (first estimates). Next: repeated reversals to average down the ±0.01–0.02° per-move noise, then the same with anti-backlash values set, to find the values that cancel it.

## O10. Altitude variable-rate moves run about 3% fast

- **Seen:** 2026-10-29. Every altitude move turned the encoder 2–3% more than rate × time: 0.204–0.208° for 0.200° (run log `2026-10-30T04-55-22`), 0.515° for 0.503° (`2026-10-30T03-50-17`), 0.102–0.103° for 0.100°. The gyroscope agrees, so the tube moves that far; it isn't the encoder. Azimuth stays within about 1% (0.196–0.200° for 0.200°).
- **Unknown:** whether it's a fixed scale (the altitude motor controller's rate units or gearing differ from azimuth's) or depends on load or direction.
- **Status:** measured. Gotos by position would sidestep it; timed moves need a per-axis rate scale if precise travel matters.

## O11. Our stop doesn't end a goto

- **Seen:** 2026-10-30 (run log `2026-10-30T16-41-01`), the stop-during-goto trial of ADR 0014. A slow azimuth goto of +2,330 units (0.05°) left at 0 ms; the axis read +1,008 at 160 ms. The stop went out at 197 ms: tracking off (`T 00`, answered in 58 ms), then fixed rate 0 (answered at 296 ms). The axis read +2,339 at 340 ms and settled on its target, +2,330, at 420 ms: as if no stop had been sent.
- **Also seen in the same session:** slow gotos (`P 04 dev 17 …`) run at about 0.29 °/s mid-flight over 0.05° and still accelerating, on both axes; nine gotos of 0.0064–0.05° each way ended within ±1 unit (0.08″) of their targets, overshot by 0–11 units, and settled in 0.4–0.75 s. The goto-finished flag can read done while the position still settles by a few units. One read of it took about 540 ms (as in O7).
- **Slow-goto profile over 0.2°** (run log `2026-10-30T17-07-19`): it cruises at about 0.5 °/s (≈1,850 units per 80 ms read), covers 0.199° in about 0.6 s, overshoots 1 unit and settles in 0.83 s.
- **A new goto ends it** (same run log). A slow −0.199° goto was stopped at 327 ms, 4,585 units in: the adapter read the position and sent a slow goto there first, then tracking off and fixed rate 0. The axis decelerated (about 2 °/s² from 0.5 °/s), read done at 544 ms and settled at 7,457 units: 2,872 units (0.062°) past the re-aim point and 1,817 units (0.039°) short of its target. It didn't come back to the re-aim point: a target behind it seems to mean "stop now". An earlier try that re-aimed after the 100 ms of tracking off and fixed rate 0 came too late to show anything (`2026-10-30T17-04-33`).
- **Status:** worked around: a stop for an axis with a goto running first re-aims the goto at the position just read (ADR 0014). It ends within about 0.06° and 0.2 s from slow-goto speed. Gotos are capped at 0.2° for now.

## O12. Altitude encoder scale checked against gravity

- **Trial:** 2026-10-30 (run log `2026-10-30T17-07-19`, phone session `6e390138`): ten altitude moves of 2° (1 °/s for 2 s), five up and five down, about 6 s apart, tube from 50.5° to 60.6° and back. For each pause, the mount's own altitude against the angle the phone's gravity vector turned about the rotation axis (found from the gyroscope, 1.4° from horizontal, so mount levelling and phone alignment don't matter).
- **Result:** the tube turned 0.996 (fused gravity) to 0.998 (raw accelerometer) of what the encoder reported, so 46,690–46,790 units per tube degree against the nominal 46,603 (2²⁴/360). That 0.2–0.4% is about what the phone's accelerometer can resolve over 10° (residuals 35–70″), so the nominal scale holds to about 0.3%. Fitting the up and down legs separately, the down leg sits 0.02–0.04° above the up leg: the altitude backlash, larger than O9's first estimate.
- **Leading edge:** at the estimated 285 mm from the axis, 1 mm is about 9,370 units (0.20°) and one unit about 0.11 µm, to the same 0.3%.
- **Pitfall:** each runner process starts its own Mac clock near 0, so samples must be placed by their phone timestamps through the clock exchanges of the runner in question (its `mac_clock_boot_id`), not by receive time: a first pass that windowed by receive time mixed sessions and gave a false scale of 0.5.
- **Status:** measured for altitude. Azimuth needs another reference (the gyroscope's own scale, or a known angle).

## O13. Altitude backlash at different tube angles

- **Trial:** 2026-10-30 (run logs `2026-10-30T17-07-19` for 45°, `2026-10-30T17-26-24` for 20°, 70° and 84°; phone session `6e390138`). At each angle, twelve slow altitude gotos of 0.15° (`+ + − −` three times), 6.5 s apart, re-arming at each angle so the gyroscope's offset was measured at that tilt. Tube motion per goto from the gravity vector's turn about the rotation axis, averaged over the still pause after each goto; the encoder from the mount's own positions.
- **Result** (lost motion on a reversal, encoder minus tube; two or three reversals each way per angle, scatter about ±20″):

  | Tube angle | Up after down | Down after up |
  |---|---|---|
  | 20° | 116″ (and 117″ in an earlier partial set) | 92″ (112″) |
  | 45° | 80″ | 70″ |
  | 70° | 108″ | 104″ |
  | 84° | 99″ | 81″ |

  Gotos in the same direction as the one before lost 0–20″. So the altitude backlash is 70–120″ (0.02–0.03°), about the same both ways and at every angle tried: with the balance of the day, gravity doesn't hold the gears to one side anywhere from 20° to 84°. It is about 40% of azimuth's (245″, O9). At 285 mm from the axis, 100″ is about 0.14 mm at the leading edge.
- **Gyroscope:** with its offset measured at 50°, the gyroscope read up and down gotos at 20° about 0.01° apart per goto (its offset shifts with tilt). Re-arming at each angle removed that.
- **Status:** measured. A different balance (accessories moved, tube slid in the bracket) may change it; repeat after rebalancing.

## O14. Fast gotos, and anti-backlash acts on timed moves but not on gotos

- **Fast gotos** (`P 04 dev 02 …`, run log `2026-10-30T17-46-42`): eight per axis, 0.02–0.2° each way. All ended within ±1 unit of target, overshot at most 19 units (1.5″), and settled in 0.35–0.9 s. Over 0.2° they peak at about 0.70 °/s on both axes (about 2,650 units per 80 ms read), against about 0.5 °/s for slow gotos: over these distances both are limited by acceleration.
- **Anti-backlash on gotos** (azimuth, twelve slow 0.15° gotos `+ + − −` per setting; run logs `2026-10-30T17-54-39` at 0, `17-56-23` at 20, `17-58-16` at 70, `18-00-00` at 99). The IMU's travel on reversal gotos was 0.086–0.102° at every setting, against 0.139–0.157° for gotos the same way as the one before: about 0.05° lost on each reversal, with or without anti-backlash.
- **Anti-backlash on timed moves** (0.2 °/s for 0.75 s, the same pattern): at 0 (run log `18-03-21`), reversals 0.086–0.114°, same way 0.132–0.152°; at 99 (`18-00-00`), reversals 0.142–0.165°, same way 0.141–0.152°. At 99 the lost motion is gone, perhaps over-corrected by about 0.01°. The take-up on one reversal turned the axis at 0.40 °/s for a 0.2 °/s move, which latched `Overspeed` (correctly, as the check stands).
- **Meaning:** the motor controllers apply anti-backlash to rate slews (the arrow keys, ASIAIR) and not to pass-through gotos. Gotos need the approach flag to land the same way each time.
- **Also seen:** a `z` position read took about 1 s and held a goto past the 1 s send deadline (`17-50-56`); the deadline is now 2.5 s (O7).
- **Status:** measured for azimuth. Next: the value between 70 and 99 that just cancels it on timed moves, the same for altitude (about 100″ of backlash, O13), and an overspeed allowance for the take-up while anti-backlash is set.

## O15. Anti-backlash values for timed moves

- **Trial:** 2026-10-30, timed moves of 0.15° (0.2 °/s for 0.75 s), `+ + − −` three times per setting, both directions of the axis set to the same value; lost motion is the IMU's travel on moves continuing the same way minus its travel on reversals (five reversals, six repeats each; scatter about ±20″). Run logs `2026-10-30T18-03-21` to `2026-10-30T19-22-14`.
- **Azimuth:** 0 → 166″ lost, 30 → 123″, 50 → 31″, 70 → −23″ (over-corrected), 85 → −15″, 99 → −38″. Confirmed at **60: +4″**. Keypad-rate moves have less slack and want 40 (O16), which the mount now holds.
- **Altitude:** 0 → 69″, 30 → 34″, 60 → −64″. Confirmed at **40: −12″**. Keypad-rate moves want 20 (O16), which the mount now holds.
- **Not linear:** little effect below about 30, then most of it between 30 and 60. The best values are about 60 (azimuth) and 40 (altitude), in proportion to each axis's backlash (O9, O13). They apply to timed moves only (O14). The mount and `config/mount.toml` held 60, 60, 40, 40 until O16 chose 40 and 20 for keypad moves.
- **Take-up:** the motor runs fast at the start of a reversal, peaking at 0.66–0.88 °/s for about 120–160 ms at 99 (gyroscope, raw). That latched `Overspeed` until the runner allowed it (`takeup_overspeed_deg_s`, `takeup_ms`): now for any move that reverses its axis, or is the first on it since the runner started, as the gears may have been left either way by whatever moved them last.
- **Servo easing:** after a move with anti-backlash 30, the axis eased back 16 units (1.2″) about 0.6 s after the move ended; the idle-creep check now waits for two equal reads before taking its reference.
- **Status:** chosen for timed moves. Repeat after rebalancing (O13), and at other tube angles if altitude behaviour matters there.

## O16. Keypad rates: speeds, and anti-backlash at each

- **Trial:** 2026-10-30 (run log `2026-10-30T20-04-30`), azimuth, anti-backlash 60. Keypad-rate moves (`MC_MOVE_POS`/`NEG`, as the arrow keys and ASIAIR's guide pulses send them, references.md) of 1.5 s at rates 1–7, `+ + − −` per rate. Speed from the encoder on the moves that repeat a direction; take-up as the encoder's extra on reversals; lost motion as the IMU's travel on repeats minus on reversals.
- **Speeds:** 1: 0.0022 °/s (0.5× sidereal), 2: 0.0045 (1.1×), 3: 0.0179 (4.3×), 4: 0.0358 (8.6×), 5: 0.0717 (17×), 6: 0.287, 7: 1.07 °/s. Rates 1–5 run at about half of Celestron's list (2, 4, 8, 16, 32× sidereal); rates 6 and 7 match it (0.3, 1 °/s). Whether ASIAIR's change to rate 1 (references.md) set the table this way isn't known.
- **Anti-backlash acts on keypad moves at the slower rates:** on a reversal the motor turned an extra 265″, 264″, 253″, 240″ and 216″ at rates 1–5 (about the azimuth backlash, 245″, O9), 123″ at rate 6, and none at rate 7, where the tube lost 191″ (the follow-up below: at rate 5, 60 gives a little less than the backlash). At rates 1–5 the IMU suggests a reversal moved the tube 40–100″ more than a repeat (over-correction), but those moves are 0.003–0.1° and the IMU figures there are noisy.
- **Meaning:** for the arrow keys and guiding (rates 1–5), anti-backlash 60 takes up the slack, perhaps more than fully; at rate 6 partly, at rate 7 not. Gotos ignore it (O14).
- **Also (discovery `2026-10-30T20-04-03`):** the motor controllers' own approach setting (`MC_GET_APPROACH`) reads positive on both axes, yet pass-through gotos finish in either direction (O14), so they don't use it. `MC_AT_INDEX` got no answer from azimuth: apparently no index marker.
- **Follow-up (2026-10-30, runs `20-04-30` (continued) to `21-48-11`):** encoder travel per move, `+ + − −` in azimuth.
  - **Rate 6's take-up doesn't depend on move length:** about 118″ extra on reversal at anti-backlash 60 for moves of 0.3, 0.6, 1 and 2 s (114, 119, 123, 118″), so it all happens at the start. The speed ramp isn't too short for it; the firmware gives less.
  - **Take-up against the setting:**

    | Anti-backlash | Rate 5 | Rate 6 |
    |---|---|---|
    | 30 | 129″ | 19″ |
    | 60 | 218″ | 123″ |
    | 99 | 330″ | 193″ |

    Rate 5 grows about 2.9″ per step: 60 falls a little short of the azimuth backlash (245″, O9) and about 70 would match it. Rate 6 gets 100–135″ less than rate 5 at every setting, not a fixed fraction, and doesn't reach the backlash even at 99.
  - **Rates 7–9** (with `config/trials/fast-rates.toml`, which relaxes the rate, duration, motion and stop limits): rate 7 about 1.04 °/s, rate 8 about 2.07 °/s, neither with a take-up measurable above the stop-timing noise (±50–100″ at these speeds). Rate 9's top speed isn't read directly (no reads during a move): at least 3.5 °/s, about 4 °/s on Celestron's list. A 1 s rate 9 move travels 3.4°; from the stop the axis takes 1.3–2.7 s and about 2.5° to come to rest, which trips the normal 1.5 s stop deadline. At rate 9 the phone's slight tilt shows 0.1 °/s on the altitude axis, enough to trip the unexpected-motion check (the altitude encoder didn't move).
- **Choosing azimuth anti-backlash for keypad moves** (2026-10-30, run logs `21-58-52` (70) and `22-18-33` to `22-24-18`; reversals at rate 5 for 1.5 s and rate 3 for 2 s, `+ + − −`; over-correction is how much further the tube (IMU) moves on a reversal than on a repeat):

  | Anti-backlash | Rate 5: motor extra | Rate 5: over-correction | Rate 3: motor extra | Rate 3: over-correction |
  |---|---|---|---|---|
  | 35 | 144″ | −28 ± 16″ | 169″ | +27 ± 19″ |
  | 40 | 160″ | +2 ± 21″ | 186″ | +7 ± 35″ |
  | 50 | 185″ | +7 ± 14″ | 219″ | +57 ± 16″ |
  | 70 | 244″ | +95 ± 18″ | 287″ | +148 ± 48″ |

  The slack on keypad moves is about 160–180″, less than O9's 245″ from slow variable-rate moves, so taking up 245″ (70) over-corrects, and so does 60. **40** balances both rates. The mount and `config/mount.toml` now hold azimuth 40; timed moves were best at 60 (O15), so they keep about 75″ of slack. Altitude stays at 40 (from O15, not checked for keypad moves). Each row rests on 4–7 reversals: enough to rule out 60–70, not to tell 40 from 45.
- **Disturbances during these trials:** two false `UnexpectedMotion` faults with the encoders still. Footsteps as the operator left the room (carpet over a wood subfloor) rocked the tube about 0.1 °/s in pulses about a second apart, tilting it about 160″ before it settled. A text message to the phone showed as a jolt peaking at 7 °/s, gone within 0.5 s. Both are larger than the effects measured here: run trials with the phone on Do Not Disturb and nobody near the scope. The taped phone's angle on the tube held within about 0.02° through the rate 9 moves, but rose 0.12° between the morning's and afternoon's sessions with the altitude encoder unchanged (app restart, tape creep or the tube settling: unknown).
- **Altitude, the same way** (2026-10-30, run logs `22-54-28` to `23-03-10`, tube at 50°):

  | Anti-backlash | Rate 5: motor extra | Rate 5: over-correction | Rate 3: motor extra | Rate 3: over-correction |
  |---|---|---|---|---|
  | 0 | 0″ | −75 ± 17″ | 0″ | −74 ± 16″ |
  | 20 | 82″ | +11 ± 14″ | 118″ | −1 ± 22″ |
  | 40 | 140″ | +55 ± 14″ | 186″ | +93 ± 18″ |
  | 60 | 192″ | +111 ± 13″ | 253″ | +140 ± 28″ |

  The slack is about 75″ (O13: 70–120″), the same up and down at this angle, and altitude runs at azimuth's keypad speeds. **20** balances both rates. Chosen for the arrow keys: the mount and `config/mount.toml` now hold 40, 40, 20, 20 (timed moves would want 60 and 40, O15).
- **Status:** keypad anti-backlash chosen for both axes at a tube angle of 50°. O13 found altitude backlash similar at other angles; not rechecked with keypad moves.

## From earlier use (not yet reproduced)

Problems from about two years ago, before this project, without a known sequence. To be pinned down one at a time once basic motion is characterized; fill in details as they come back.

- **H1. ASIAIR:** problems controlling or connecting to the mount (details to add). ASIAIR was connected through the hand controller's USB port (where the Mac is now), and SkySafari may have been connected over the mount's Wi-Fi at the same time. Typical night: StarSense alignment, then ASIAIR, then the USB link hung or moves stopped, forcing a power cycle that lost the alignment. ADR 0016 sets out to reproduce it.
- **H2. StarSense self-calibration:** problems with auto-alignment or calibration (details to add).
- **H3. Tracking:** problems with tracking (details to add). O1's creep is a candidate for some of these.
- **H4. Hand controller arrow keys:** unexpected behaviour of arrow-key moves (details to add). O1 may be one.
