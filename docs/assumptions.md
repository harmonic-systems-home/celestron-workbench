# Assumptions that still need physical verification

Items are unverified unless the results log at the end says otherwise. Each item names the milestone that settles it. Record the outcome here, with the date, device, OS and firmware versions, and keep the evidence in the private data store.

## iPhone and Core Motion (M1, M3)

| # | Assumption | Why it matters | How to verify |
|---|---|---|---|
| P1 | `CMLogItem.timestamp` is seconds since boot on the same clock as `ProcessInfo.systemUptime`, and pauses while the device sleeps. | ADR 0001 treats both as one phone clock domain. | Log both side by side in a session; lock the screen in the designated interruption test and look for a jump. |
| P2 | Device motion, raw gyro and raw accelerometer can all run at the requested interval on the iPhone 17 Pro Max at the same time without throttling. | Sets the effective sample rate and the gap budget. | Measure the observed interval distribution for several requested rates; record thermal state. |
| P3 | Core Motion reports accelerations in g and rotation rates in rad/s, using the documented device frame (+X right, +Y top, +Z out of screen). | ADR 0002 conversions and frame. | Lay the phone flat (gravity ≈ −Z), then on each edge; rotate by hand about each axis and check the sign. |
| P4 | `CMQuaternion` is Hamilton, scalar `w`, rotating device-frame vectors into the reference frame. | Every orientation calculation. | Compare the quaternion with gravity and a known 90° rotation on the fixture. |
| P5 | Attitude stays continuous while the app is in the foreground and resets only after interruptions or reference-frame changes. | Discontinuity detection and segmentation. | Watch for jumps across the interruption tests. |
| P6 | Magnetometer readings near the mount are unreliable for heading. | Magnetic frames are treated as experimental. | Compare readings with the mount unpowered, powered and idle, and moving. |
| P7 | The app keeps sampling with the screen on and the app in the foreground for at least a 30-minute trial. | Phase 1 stationary trials. | Run a 30-minute trial and check the gap count and thermal state. |

## Network (M1, M2)

| # | Assumption | Why it matters | How to verify |
|---|---|---|---|
| N1 | The home Wi-Fi allows phone-to-Mac TCP connections (no client isolation) and Bonjour discovery works on it. | ADR 0004 transport. | Connect the logger to the receiver; check discovery. |
| N2 | The network is trusted: v1 has no encryption or authentication beyond a device ID. | Anyone on the network could inject samples. | Confirm before relying on it; otherwise add TLS or a pairing key. |
| N3 | Round-trip latency and jitter are low enough for the clock exchange to reach useful uncertainty. | Response-timing metrics (Phase 1 acceptance). | Measured by the clock model (Prompt 4). |
| N4 | macOS will allow the receiver to accept incoming connections (firewall, local network permission). | The receiver must be reachable. | First run of the receiver. |

## Mount (M5; nothing here is tested until the simulator gate passes)

| # | Assumption | Why it matters | How to verify |
|---|---|---|---|
| M1 | The NexStar Evolution's command path from the Mac (hand controller USB/serial, or Wi-Fi) supports documented non-motion queries. | Read-only discovery (Prompt 7). | Discovery tool traces. |
| M2 | Manual-rate (fixed slow-rate) single-axis motion commands exist and stop on a documented stop command. | The only motion the test runner will send. | Compatibility report against Celestron documentation, then the hardware dry run. |
| M3 | Cutting mount power stops motion immediately and safely, and is reachable from the operator position. | The independent stop (ADR 0005). | Hardware dry run before any software-commanded motion. |
| M4 | StarSense and the mount's own alignment state do not change how manual-rate commands behave. | Repeatability across sessions. | Compare trials with and without alignment. |
| M5 | Firmware limits (altitude slew limits, cord wrap) remain active under manual-rate commands. | Layer 2 of the safety design. | Confirm in documentation; observe carefully at low rate. |
| M6 | A long move in one direction turns the axis through very nearly its commanded angle (backlash affects reversals, not the total of a one-way move). | The scale reference for on-scope characterization (ADR 0009). | Repeat long one-way moves and check they agree; compare with plate solving if Prompt 9 is reached. |

## Attachment (M3)

| # | Assumption | Why it matters | How to verify |
|---|---|---|---|
| A1 | A rigid, non-magnetic holder can hold the phone on the scope repeatably, so that remove-and-replace error is below the sensor noise. | Otherwise the holder dominates every measurement. | Remove-and-replace on the scope, measured with still windows before and after (ADR 0009). |
| A2 | ~~The available turntable or indexed fixture has a known angle uncertainty.~~ | Dropped: no bench fixture (ADR 0009). | |

## Results log

### 2026-10-28: first bench recording (M1)

iPhone 17 Pro Max, iOS 26.6.2, logger 0.1.0 (1). Phone on a table, logging to the phone only, requested interval 10 ms with device motion, raw gyro and raw accelerometer enabled, reference frame `x_arbitrary_z_vertical`. About 94 s: 15 s settling, 50 s still, one hand rotation of about 90° clockwise seen from above, then pick-up. The log is kept in the private data store.

| # | Outcome | Evidence |
|---|---|---|
| P2 | **Confirmed at 100 Hz requested.** All three streams delivered 99.63 Hz (10.037 ms interval, spread ±1.5 µs), with no gaps, no out-of-order timestamps and no drops. Thermal state stayed nominal. Other rates are not yet tested. | 27,931 samples, seq contiguous; interval min 10.036 ms, max 10.039 ms. |
| P3 | **Confirmed for gravity and Z rotation.** Flat and screen up, gravity was (−0.04, −0.14, −9.806) m/s² (0.9° tilt). A clockwise rotation seen from above gave a negative Z rotation rate, as the right-hand rule about +Z out of the screen predicts. The X and Y axes and the edge orientations are not yet tested. | Raw accelerometer magnitude was 9.833 m/s² (+0.27 %, within factory scale error); fused gravity magnitude was 9.80665. |
| P4 | **Consistent so far.** The attitude change across the rotation (88.02°, yaw +0.05° → −87.97°) matched the integrated fused Z rate (−88.00°). | Needs a fixture with a known angle (A2) to check absolute accuracy. |
| P5 | No discontinuities while in the foreground. Yaw drift while still was 0.03°/min. Interruptions are not yet tested. | Discontinuity counter 0. |

Also noted: the raw gyro bias while still was up to 0.0042 rad/s (0.24°/s) per axis, with noise of about 0.0008 rad/s; the fused rotation rate removes the bias. Device motion started about 0.4 s before the raw streams.

### 2026-10-28: first live session to the Mac receiver (M2)

Same phone and settings as above, streaming over home Wi-Fi to `cwb receive` (Bonjour discovery) instead of logging to the phone only. About 48 s: flat on a table, then held by hand upright in portrait, then on its right edge in landscape. Poses were found from the motion; the markers were placed before each move finished, so they are not pose boundaries. The session is kept in the private data store.

| # | Outcome | Evidence |
|---|---|---|
| N1 | **Confirmed.** The phone found the receiver by Bonjour and streamed the whole session over TCP. On the first try the phone did not see the receiver until the app was relaunched; the app now restarts discovery when it returns to the foreground or after a failure. | 14,439 samples, seq contiguous, no gaps or resends, status `ended`; 99.62–99.64 Hz per stream. |
| N4 | **Confirmed.** macOS accepted the incoming connection. | |
| P3 | **Confirmed for gravity on −Y and +X, and for X and Y rotation.** Upright in portrait, gravity was (−0.01, −9.742, −1.122) m/s² (−Y, screen leaning back 6.6°). On the right edge in landscape it was (+9.798, −0.04, −0.34) m/s² (+X). Raising the top edge from flat gave a positive X rotation rate, and tipping the right edge down gave a positive Y rotation rate, as the right-hand rule predicts. The −X and +Y edges and screen-down are not yet tested. | Flat → upright: gravity moved 82.58°; integrated gyro +83.1° about X with under 3° on the other axes. Into landscape: about +81° about Y, with the other axes mixed in by hand. |
| P4 | **Consistent.** The attitude change from flat to upright (82.58°, rotation vector (+82.6, −0.5, −0.8)° in the starting device frame) matched the gravity change and the integrated gyro to 0.5°. | Absolute accuracy still needs the fixture (A2). |

Also noted: raw accelerometer magnitude was 9.823 m/s² with Z down, 9.799 with −Y down and 9.780 with +X down (spread about 0.4 %); fused gravity stayed at 9.80665. Separating per-axis bias from scale needs all six faces. Hand-held poses wobbled at about 6.7°/s RMS, against 0.09°/s on the table, so later pose checks should rest the phone on a surface. The phone's marker label field had autocorrect on, which turned "Horiz" into "Boris"; it is now off.
