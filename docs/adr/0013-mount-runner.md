# ADR 0013: The Celestron motion adapter and the interactive mount runner

**Status:** Accepted

## Context

Plan Prompt 8 calls for a Celestron adapter and an interactive runner that starts disarmed, allows one short low-speed move at a time, confirms each first hardware test, logs every stage of every command, has a prominent stop, and auto-stops on every interlock. The hardware gate (ADR 0005) is met: the simulator safety suite passes and the discovery report for this mount (ADR 0010) is approved. The interlock controller needs IMU observations in mount-axis terms on the Mac clock, which no code produced yet.

## Decision

### Motion adapter (`cwb-mount-celestron`)

- **The only code that can move hardware.** It sends only the commands the approved report proposed: pass-through variable-rate slews on one axis (`P 03 10|11 06|07 hi lo 00 00`, rate = arcsec/s × 4) and stops. A test checks every transaction it can produce against that list.
- **Stops send both forms:** variable rate 0, then fixed rate 0. The report left open which of them ends a variable-rate slew (ADR 0010, "To observe"); the first hardware trials show it.
- **A worker thread owns the serial port,** so a slow reply never blocks the controller's checks. A stop overtakes any move still queued before it. Stops are attempted even after the link looks lost. Dropping the adapter stops both axes before the thread exits.
- **Acknowledgement** is the `#` reply to a move. Three unanswered commands in a row, or a failed port, count as a lost link.
- **Axis signs** (`reverse_azimuth`, `reverse_altitude` in `config/mount.toml`) map the hand controller's positive slew onto the IMU's convention. A wrong sign shows at once as opposite motion and latches a fault; the axis-sign trial sets them.
- **Preparation** before the adapter starts: the hand controller echoes, both motors answer, no goto is running, and tracking is off. If tracking is on, `T 00` turns it off (it stops motion, never starts it) and the result is checked.
- **The mount's own axis positions** (`z`) are read every 250 ms while no command is queued and written to the run log: a second motion record, not used for safety.
- **`fake::SimHandController`** decodes the same bytes and drives the simulated mount, so the simulator's fault injection applies to the real adapter.

### Phone to mount axes (`mount_core::imu`)

- The phone is strapped to the tube with a known body axis toward the sky end (`phone.tube_axis`, default `+y`: the top of the phone). With the mount level, the azimuth axis is the vertical from gravity, and the altitude axis is horizontal and perpendicular to the tube. So azimuth rate = −ω·up, altitude rate = ω·(tube × up)/|tube × up|, and altitude = asin(tube·up). No calibration move is needed, and roll about the tube doesn't matter.
- Signs: azimuth positive clockwise seen from above, altitude positive as the tube rises.
- A tube within about 3° of vertical gives no observation (the altitude axis is undefined); the envelope stops well short of it.

### Live IMU

- The receiver gains a tap (`Server::with_tap`): a copy of each `hello`, sample batch and clock result goes to the runner as it arrives, while storage carries on unchanged. A full tap drops copies rather than slowing storage.
- The runner fits a live clock model from the session's clock exchanges (this Mac clock domain, the phone's current boot) and maps each device-motion sample's phone time to Mac time. Samples before the first model, or from another session, are ignored, so the IMU reads as stale until the phone is properly connected.

### Runner (`cwb-mount-runner`, `cwb mount run`)

- **Checklist first:** the mount-session checklist is shown and must be confirmed (`yes`) before the controller connects. Until then nothing can arm or move.
- **One line at a time.** An empty line is always Stop. `arm`, `disarm`, `az+ az- alt+ alt-` with an optional rate and duration (defaults 0.1 °/s for 1 s), `status`, `reset`, `e` for emergency stop, `quit`.
- **First move each way needs `yes`:** the first move per axis and direction shows its rate, duration and travel and waits for confirmation. Enter cancels.
- **Rates are quantized** to what the hand controller will run before the request, so commanded travel matches what is sent.
- **Run log** (`reports/mount/<time>/run.ndjson`, git-ignored): the configuration, the checklist confirmation, every operator line, request, command sent, mount report and position, state change, fault, alert and finished command with commanded and IMU travel.
- **Quit or Ctrl-C** shuts down through the controller (`StopAll`, latched), keeps ticking 1.5 s, then drops the adapter, which stops both axes again.
- **`--simulate`** runs the same runner and adapter against the simulated hand controller and mount, with the simulated mount as the IMU, to rehearse.

## Consequences

- A stop can wait behind a position read (about 85 ms) or a move in progress on the serial line. At the rates allowed (≤ 1 °/s) that is ≤ 0.1° of extra travel, inside the travel tolerance.
- Command records and mount events go to the run log only; the database tables for them (`commands`, `mount_events`) are not written yet.
- The axis-sign, rate-response, start-stop, reversal, backlash and hold protocols (plan Prompt 8) come next, each with a review gate, built on this runner.
- The Wi-Fi delay limit in ADR 0005 still applies: expect occasional stale-IMU faults.

## First hardware trial and changes (2026-10-29)

One azimuth move, 0.1 °/s for 1 s, commanded +0.100°. The hand controller acknowledged in 38 ms and the axis turned the configured way (`reverse_azimuth = false` holds). Three findings:

- **iOS's fused rotation rate hides slow rotation.** Its bias estimator treated the steady 0.1 °/s as drift: the fused rate faded to zero within about 1 s and swung to −0.08 °/s after the mount stopped. The runner read +0.114° of travel. The raw gyroscope, recorded alongside, showed a steady 0.1 °/s and then zero, plus a constant offset (about 0.15 °/s on this phone).
- **The mount moved on after the stop.** The raw gyroscope shows motion until about 1.4 s; the mount's own positions show 0.206° in all, until about 2 s. The positions may lag, and the log didn't record when each stop was answered, so the stop delay isn't settled.
- **Anti-backlash was 50 on every axis and direction** (discovery, ADR 0010). Compensation on a reversal would hide the backlash these tests measure.

Changes:

- **The safety checks use the raw gyroscope** once armed. `arm` measures its offset over the last 3 s (at least 250 samples), which must be still by the mount's own positions (within 0.002°), because a gyroscope can't tell a steady slow turn from an offset. Rates are the raw gyroscope minus that offset, turned into mount axes with gravity from the newest device-motion sample. iOS's fused rate serves only before arming, for freshness and stillness. Disarming or a reset clears the offset; the next `arm` measures it again. The Raw gyroscope setting in the app is required.
- **Every motion command's serial exchange is logged** (`serial`: bytes, outcome, send and reply times), so stop timing is measured.
- **The stop form is configurable** (`[celestron] stop = "both" | "variable" | "fixed"`) for the stop-form trial. It applies to a move's own stop; stops after a fault and on quitting always send both forms.
- **The runner refuses to start unless anti-backlash is 0** on both axes and directions (read during preparation). Set it with `cwb celestron backlash` (ADR 0011).
- **The phone's port is claimed first,** so a busy port fails before the hand controller is touched or the checklist is shown.

Next trials, each reviewed before the next: repeat the 0.1° azimuth move with serial timing; the stop-form trial (a few moves stopped with each form alone); then axis sign for altitude, rate response, start-stop, reversal and backlash, and holds. The anti-backlash values are 0 to 99 with no documented unit: moves with a known value on one direction, then a reversal, measure the unit from the extra travel, and the backlash trials give the value that cancels the real slack. Finding and writing those values is one of this project's outputs.

## Hand controller link health (2026-10-29, second session)

The USB serial device reset a few seconds after the runner opened it and came back under the same name; the runner kept the dead handle. Failed position reads were ignored, so nothing showed until a move was sent about five minutes later: the write failed at once, so nothing moved, but the session went straight to a latched link fault.

- **Failed position reads count against the link** like failed commands: a failed port is lost at once, three unanswered reads in a row are lost. The operator is told once, with a hint to restart the runner.
- **`arm` and every move need a position read within the last second.** Positions are read every 250 ms while idle, so a live link always has one.
- **While armed and idle, 1.5 s without a position read is a lost link** (latched, with the usual stop attempts). Time spent moving or stopping doesn't count, because no positions are read then.
- **`status` says whether the IMU is fresh or STALE** and how old the last mount position is.
- **The phone app retries a connection that isn't ready within 5 s.** An unadvertised Bonjour name never fails on its own, so the app used to wait at its first attempt until the recording was restarted.

A runner whose port has reset must be restarted; it doesn't reopen the port itself.

## Second trial: stop timing (2026-10-29)

Same move, now on the raw gyroscope and with serial timing. Acknowledged in 35 ms; the mount's own positions show motion from about 0.1 s. The controller asked for the stop at 1002 ms, but it reached the serial port only at 1209 ms: it had queued behind a position read, which the hand controller answers slowly while a motor slews. Once sent, the mount stopped within about 0.1 s. Travel: 0.121° by the mount's positions, 0.130° by the raw gyroscope, 0.100° commanded. The first trial's long overrun was most likely the same queueing.

- **No position reads between a move and its stop.** The worker resumes them once a stop has gone out.
