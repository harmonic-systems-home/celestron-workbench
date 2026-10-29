# ADR 0007: Mount characterization uses step-and-settle and hold tests

**Status:** Accepted

## Context

The plan's Phase 2 test matrix (plan § Low speed test matrix) measures several results in time: onset delay, stop delay and reversal dead time. Those correlate Mac command times with phone sample times, so their quality is limited by phone–Mac clock alignment over Wi-Fi. Our first live session showed receive latency of 67 ms median and up to 1.1 s, and drift between two crystal clocks of roughly 1–20 ppm (about 18 ms over 30 minutes at 10 ppm).

The operator's prior positioner work (backlash and drivetrain characterization) used a "Move and Measure" pattern instead: command a move, wait until it is complete, measure the position, then command the next. Measurements are taken while still, not during motion.

## Decision

- **Primary method: step-and-settle ("Move and Measure").** A sequence commands a small move on one axis, waits for the mount to report completion, holds still, and measures. A typical run is N steps of +Δ, then N steps of −Δ, repeated 3–5 times. Results per axis:
  - **Scale:** measured versus commanded angle per step.
  - **Reversal deadband:** commanded motion after a direction change that produces no measured motion. Reported as system deadband, not drivetrain backlash, until the optical check separates flex and attachment play (plan § Backlash interpretation).
  - **Repeatability:** spread across repeats at the same commanded position.
  - **Settling and creep:** motion seen by the phone after the mount reported completion.
- **Measurement windows come from the phone.** Analysis finds still windows in the IMU stream and pairs them with commands by order. Each window is averaged to one orientation. Timestamps only need to bracket a window (after "move complete", before the next command), so clock alignment of tens of milliseconds is enough.
- **The phone detects settling live.** The logger runs the stillness detector on-device and sends a `settled` report (window start and end, mean orientation and gravity, spread) so a sequence can command the next step as soon as the mount is still instead of after a fixed dwell. The raw stream keeps flowing alongside it. A settled-only mode that stores reports without the raw stream may follow once the on-phone detector has been checked against raw data from real runs: the same detector runs in Rust analysis, and its windows must match the phone's.
- **Completion is checked twice.** The mount's own completion report and IMU stillness must both hold. Disagreement is recorded as settling or creep, not discarded.
- **Hold test for stability.** The mount is parked at a fixed pose with tracking off for 10–30 minutes while the phone records. Repeat at several altitudes. Results are total droop and its time course (settles or keeps creeping). Hours-long holds are out of scope: tracking corrects slow drift and droop in normal use.
- **Every hold has a bench baseline.** A recording of the same length with the phone on a rigid table measures the phone's own stability. Mount droop is what exceeds the baseline.
- **Step sizes are not fixed yet.** They follow from two measurements:
  - **Phone resolution** (plan Prompt 5): noise versus averaging time for tilt and heading, which sets the settle-window length and the smallest detectable angle.
  - **Mount command resolution:** a step-size sweep that commands progressively smaller moves until the measured motion either drops into the phone's noise or stops tracking the command.
- **Clock estimation stays basic.** Every session records four-timestamp exchanges and a linear offset-and-drift fit per clock domain (ADR 0001), enough to bracket windows and to report alignment uncertainty. Robust fitting is deferred until a test needs sub-100 ms timing.

## Consequences

- The time-based rows of the plan's test matrix (onset delay, stop delay, reversal dead time) are deferred. Each can return later if the clock model's uncertainty supports it.
- **Altitude is the strong axis.** Tilt comes from gravity and does not accumulate drift. Azimuth comes from the integrated gyro, which drifted 0.03°/min on the bench; step-and-settle runs must return to earlier positions so that drift can be fitted and removed, and hold tests can only bound azimuth creep roughly. Azimuth stability needs the optical check (plan Prompt 9).
- **Temperature matters over tens of minutes.** The phone warms after recording starts, and accelerometer bias shifts with temperature (1 mg reads as about 0.06° of tilt). Hold tests start after a 10–15 minute warm-up; the logger records thermal state. Room and tube temperature should be steady.
- **Raw data costs about 5.5 MB per minute** (100 Hz, three streams), roughly 165 MB for a 30-minute hold. That is acceptable on the Mac and is what makes settle thresholds, creep and vibration re-analysable later; a settled-only mode trades that away.
- If the phone's resolution turns out coarser than the mount's deadband, the IMU cannot measure it, and the optical check moves earlier.
