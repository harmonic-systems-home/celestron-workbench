# Celestron Workbench — Project Plan

*Implementation-ready project plan for Claude Code.*

Bench characterization first, followed by controlled NexStar mount diagnostics and later astronomical reference integration.

Target hardware: iPhone 17 Pro Max, MacBook, Celestron NexStar Evolution 8 EdgeHD with StarSense.  
Preferred Mac implementation: Rust. iPhone implementation: Swift and Core Motion.

Plan version 1.0 — 28 October 2026

Prepared as a build specification. Sensor rates, available Core Motion fields, mount firmware behavior, connection paths, and command semantics must be discovered and recorded at runtime rather than assumed.

# Executive direction

Build the system in evidence gates. The first deliverable is a bench instrument that measures the phone and attachment method before it controls a telescope. The Mac receives timestamped iPhone motion data, stores an immutable session log, and produces a reproducible report for stationary noise, drift, timing, and known relative rotations. Mount control begins only after that report passes its acceptance criteria and the operator can stop motion independently of the software.

The phone can be useful for relative rotation, rate, settling, reversal response, and fault detection. It should not be treated as a high accuracy absolute encoder. Gyroscope integration drifts; gravity constrains tilt but not heading; magnetic heading is vulnerable to the mount, motors, steel, cables, and indoor fields; and Core Motion fusion behavior is not a metrology guarantee. Outdoor plate solving supplies the later absolute celestial reference.

## Project outcomes

- A Swift iOS logger that streams raw and fused motion samples with explicit timestamps and metadata.

- A Rust Mac receiver, local database, command service, analysis pipeline, simulator, and report generator.

- A synchronized record of requested mount commands, acknowledgements, observed motion, derived response, warnings, and operator actions.

- Repeatable altitude and azimuth tests for onset, speed, settling, reversal, backlash, stiction, missed motion, and unexpected motion.

- A staged route to camera and plate solve truth, followed by optional ASIAIR data exchange without making ASIAIR a safety dependency.

## Scope boundaries

| **In scope** | **Deferred or excluded** |
|----|----|
| Local single operator diagnostic system | Autonomous unattended slewing |
| Relative motion and fault characterization | Claiming phone orientation as arcsecond absolute truth |
| Bench and indoor low speed mount tests | Bypassing Celestron safety limits or firmware |
| Documented local data and reproducible analysis | Cloud service requirement |
| Later plate solve and ASIAIR interoperability | Reverse engineering proprietary behavior when a supported interface exists |

## Acceptance strategy

Use two kinds of thresholds. Hard safety thresholds are fixed before a mount session and stop motion when exceeded. Measurement thresholds are baselined from the actual phone, attachment, sampling mode, and environment during Phase 1. Do not invent universal accuracy numbers. Store the baseline, compute confidence intervals, and make every later pass or fail decision traceable to a named baseline version.

# System architecture

```text
iPhone Swift app
Core Motion acquisition → timestamp normalization → bounded buffer → local NDJSON backup
→ Network.framework stream over trusted local Wi-Fi

Mac Rust workspace
receiver → session clock model → SQLite writer → live monitor
mount adapter → command interlock → Celestron transport
analysis crate → plots and machine-readable results → HTML and Markdown report

Later truth sources
camera capture → plate solver → celestial orientation observations
ASIAIR import or supported integration → correlated events and images
```

## Architecture decisions

| **Decision** | **Choice** | **Reason** |
|----|----|----|
| Phone transport | Local Wi-Fi first | Core Motion has no general direct USB sensor-stream API. A Lightning or USB C cable does not make an iPhone a generic serial peripheral. USB networking or accessory protocols add entitlement and hardware constraints. |
| Mac language | Rust | Strong types, explicit concurrency, reliable binaries, SQLite and plotting ecosystem, and a clean boundary around hazardous commands. |
| Storage | SQLite plus immutable raw export | Transactions and queries for normal use; newline-delimited JSON provides inspectable recovery and replay. |
| Clock model | Separate source and receive clocks | Phone monotonic time orders samples; Mac monotonic time orders commands. Periodic ping exchanges estimate offset and uncertainty. |
| Mount interface | Adapter with simulator first | Protocol details, firmware responses, and physical connection paths vary. A simulator lets safety and analysis mature before hardware motion. |
| Analysis | Versioned command line pipeline | Every chart and metric must be regenerable from stored session data and a committed analysis configuration. |

## Components and responsibilities

| **Component** | **Primary responsibilities** |
|----|----|
| ios ImuLogger | Discover sensor availability; collect CMDeviceMotion, gyro, accelerometer, magnetometer when available; expose reference frame; batch, stream, and retain a local fallback. |
| mac ingestd | Authenticate one phone, validate schema, estimate clock relationship, detect gaps, and write append-only events. |
| mac mountd | Own the mount connection and command lease; enforce axis, rate, duration, limit, stale-data, and emergency-stop rules. |
| mac observer | Show connection state, live rates, orientation deltas, dropped samples, command state, limits, and stop control. |
| analysis | Run stationary, rotation, latency, response, reversal, settling, backlash, and anomaly computations. |
| report | Render session manifest, configuration, exclusions, metrics, plots, acceptance decisions, and provenance. |
| simulators | Replay IMU logs and emulate mount acknowledgements, delays, stalls, reversals, and faults. |

# Implementation repository

```text
celestron-workbench/
README.md                       operator entry point
docs/                           architecture, protocol notes, safety cases
ios/ImuLogger/                  Swift app and tests
rust/Cargo.toml                 Rust workspace
rust/crates/protocol/           shared wire types and schema validation
rust/crates/ingest/             phone receiver and clock estimation
rust/crates/storage/            SQLite migrations and repositories
rust/crates/mount-core/         command state machine and interlocks
rust/crates/mount-sim/          deterministic simulator
rust/crates/mount-celestron/    hardware adapter after protocol validation
rust/crates/analysis/           metrics and plots
rust/crates/cli/                session and report commands
analysis/                       versioned configurations and notebooks if needed
schemas/                        JSON Schema and SQL migrations
fixtures/                       synthetic and sanitized reference sessions
reports/                        generated locally and ignored except examples
```

Keep acquisition, storage, analysis, and hardware control separable. The iOS app must remain useful without the mount. The analysis pipeline must accept both recorded and simulated sessions. The mount service must never infer authorization from the presence of a phone connection.

# iPhone acquisition design

## Core Motion streams

- Use CMMotionManager. Record the requested interval and the observed interval distribution. Query isDeviceMotionAvailable and each raw sensor availability at runtime.

- Prefer device motion for attitude, rotationRate, gravity, and userAcceleration. Also record raw gyroscope and accelerometer streams when they are available and sustainable.

- Record the selected CMAttitudeReferenceFrame. For bench relative rotations, prefer a nonmagnetic reference frame when practical. Treat magnetic north frames as experimental channels, not ground truth.

- Use sensor timestamps supplied by Core Motion as the source time. Add an app sequence number and Mac receive time. Never substitute wall clock for sample ordering.

- Capture thermal state, battery state when permitted, app state, interruptions, and effective sample rate because they can explain gaps or rate changes.

- Keep acquisition callbacks short. Copy values into a bounded queue; serialize and transmit away from the Core Motion callback queue. Count every dropped record.

## Phone coordinate frame and attachment

Define the phone body frame from the device screen and edges, then measure a fixed transform from phone frame to optical tube assembly frame. Store the attachment orientation as a quaternion and a human-readable mounting description. Use a rigid cradle with repeatable locating surfaces. A flexible strap alone can introduce motion that looks like gear or bearing behavior. Photograph or diagram each attachment revision and give it an attachment ID.

## Wire protocol

Use a versioned length-delimited message format over a trusted local connection. JSON is acceptable for the first bench build; switch to CBOR or MessagePack only after profiling. Each batch contains a protocol version, session ID, device ID, first and last sequence number, samples, and a checksum. The receiver acknowledges the highest contiguous sequence. The phone retains an NDJSON fallback and can resend missing ranges after reconnect.

# Mac Rust services

- Use Tokio for networking and task supervision, Serde for schemas, Rusqlite or SQLx for SQLite, tracing for structured logs, Clap for commands, and a deterministic plotting library or generated Vega Lite specifications for reports.

- Use one database writer task. Apply bounded channels so overload is visible. WAL mode may improve concurrent viewing, but benchmark it and checkpoint cleanly at session end.

- Represent mount commands as a state machine with one active command lease. Separate requested, transmitted, acknowledged, cancelled, completed, timed out, and rejected states.

- Provide replay mode. The live monitor and analysis code should consume the same event interface for live, recorded, and simulated sources.

- Generate a session manifest containing application versions, Git commit, schema version, analysis configuration hash, host information, and input file hashes.

# Data model

Store timestamps as integer nanoseconds in their native domains. Never imply that phone monotonic time and Mac monotonic time share an epoch. Derived aligned time must carry the clock model ID and an uncertainty estimate.

| **Table** | **Key fields and purpose** |
|----|----|
| sessions | session_id, created_utc, ended_utc, phase, operator_notes, status, schema_version, software_versions, safety_config_id, analysis_config_id |
| devices | device_id, session_id, role, vendor, model, OS or firmware, app_version, sensor_availability, reference_frame, requested_rate_hz |
| attachments | attachment_id, description, revision, phone_to_ota_quaternion, procedure, evidence_path, repeatability_notes |
| clock_sync | clock_model_id, session_id, exchange_index, phone_send_ns, mac_receive_ns, mac_send_ns, phone_receive_ns, offset_estimate_ns, round_trip_ns, uncertainty_ns |
| sensor_samples | session_id, device_id, stream, seq, source_monotonic_ns, mac_receive_monotonic_ns, aligned_ns, clock_model_id, q_wxyz, rotation_rate_xyz, gravity_xyz, user_accel_xyz, magnetic_field_xyz, accuracy_flags |
| commands | command_id, session_id, axis, direction, requested_rate, requested_duration_ms, requested_ns, transmitted_ns, acknowledged_ns, completed_ns, transport, payload_redacted, status, rejection_reason |
| mount_events | event_id, command_id, mac_monotonic_ns, type, raw_response, parsed_fields, severity |
| markers | marker_id, session_id, source, label, source_ns, aligned_ns, notes |
| derived_results | result_id, session_id, analysis_version, metric_name, axis, value, unit, uncertainty, window_start_ns, window_end_ns, inputs_hash, pass_state |
| artifacts | artifact_id, session_id, kind, path, sha256, media_type, created_utc, generator_version |

## Sensor sample rules

- Use SI units internally: radians, radians per second, meters per second squared, seconds, and nanoseconds. Reports may add degrees for readability.

- Store quaternions in a declared ordering and handedness. Never store anonymous x y z w values.

- Use null for unavailable fields. Do not fill missing samples by interpolation in the raw table.

- Keep raw observations immutable. Corrections, smoothing, frame transforms, and resampling create derived data with provenance.

- Record sequence gaps, buffer pressure, and parse errors as events even when the session continues.

# Phase 1 desktop and bench characterization

## Purpose

Determine what the specific phone, iOS version, sampling configuration, attachment, and room can measure repeatably. This phase produces the baseline used by later mount tests.

## Bench fixtures

- Rigid nonmagnetic phone cradle with repeatable placement and visible orientation marks.

- Stable surface isolated from fans, speakers, moving desks, and foot traffic.

- Controlled rotation reference. Start with a quality turntable or indexed fixture whose angle uncertainty is documented. Do not use printed marks as precision truth without validating them.

- Independent timing marker, such as a visible tap or fixture stop, for checking event alignment.

- Thermal logging and a warm-up procedure so cold-start behavior is distinguishable from steady state.

## Bench protocol

1.  Run a 10 minute warm-up with the app active and the phone fixed. Record, but exclude this interval from steady-state metrics.

2.  Record at least three stationary trials of 30 minutes in the same placement. Repeat one trial after removing and replacing the phone.

3.  Run controlled single-axis rotations at several amplitudes, including small, medium, and large movements appropriate to the fixture. Use both directions and return to the starting index.

4.  Run sequences of repeated reversals to expose hysteresis in the fixture and attachment. Pause long enough at each index to estimate settling and endpoint stability.

5.  Repeat selected trials with the mount nearby but unpowered, powered and idle, and motors moving later in the program. This isolates magnetic and vibration contamination.

6.  Close and relaunch the app, lock and unlock only in a designated interruption test, and deliberately interrupt the network to verify recovery and gap accounting.

## Bench metrics

| **Category** | **Metrics** | **Interpretation** |
|----|----|----|
| Stationary noise | Per-axis mean, standard deviation, RMS, robust MAD, percentile bands, power spectral density, Allan deviation | Characterizes short-term noise, vibration, bias stability, and time scales where integration becomes unreliable. |
| Drift | Quaternion or yaw pitch roll change versus elapsed time; integrated gyro error; endpoint return error | Quantifies relative orientation stability. Report reference frame and never hide angle wrapping. |
| Controlled rotations | Scale error, signed endpoint error, repeatability, nonlinearity, cross-axis coupling | Compares phone-derived relative rotation with the fixture reference and distinguishes scale from offset. |
| Timing | Observed interval distribution, gap rate, batch latency, clock offset uncertainty | Defines which response and latency claims later tests can support. |
| Attachment | Remove-and-replace transform change, apparent vibration, return-to-index variance | Determines whether the mounting method dominates the sensor. |
| Environment | Difference across mount power states and locations | Identifies magnetic, acoustic, structural, and thermal interference. |

## Phase 1 acceptance criteria

- All raw and derived records validate against the pinned schema, and a session can be replayed into the same metrics without the phone.

- No silent sample loss. Every missing sequence number is counted, and the report shows effective rate and gap distribution.

- The report separates warm-up, steady-state, motion, settling, and excluded windows with stored markers.

- Repeated indexed rotations produce a measured error distribution and confidence interval for each tested axis and amplitude. The result may be unacceptable; a negative result is still a successful characterization.

- Remove-and-replace error is measured. If attachment repeatability is worse than the sensor baseline, redesign the cradle before mounting on the telescope.

- Clock-alignment uncertainty is reported and is small enough for the intended response metrics. If it is not, only order-based metrics may advance.

- A clean Mac setup can ingest a fixture session and regenerate the report from documented commands.

# Calibration and validation

## Calibration layers

| **Layer** | **Method** | **Stored result** |
|----|----|----|
| Phone sensor baseline | Stationary and indexed fixture trials | Bias and noise statistics by stream, axis, thermal state, rate, reference frame, and software version |
| Phone to telescope frame | Rigid attachment plus known telescope poses or later plate solve observations | Normalized quaternion, covariance or repeatability estimate, attachment revision |
| Clock relationship | Periodic four timestamp exchanges and robust fit over time | Piecewise offset and drift model with residuals and uncertainty |
| Mount response | Low speed motion segments with stable start and stop windows | Rate scale, onset delay, stop delay, settling, deadband, reversal and backlash estimates |
| Absolute celestial reference | Camera images and plate solves | Time-stamped sky orientation and solver uncertainty linked to exposure interval |

Do not apply hidden calibration constants. Each derived value names the calibration record and software version. Recalibration creates a new record; it does not rewrite earlier raw data.

## Reproducible analysis

- Pin Rust dependencies and record the toolchain. Store migrations, JSON schemas, analysis configuration, and a small synthetic fixture in version control.

- Provide one command that validates a session and one that builds its report. Both must fail clearly on incompatible schema versions or missing provenance.

- Use deterministic random seeds for bootstrap intervals and simulation. Store the seed in derived results.

- Hash every raw export and generated artifact. Include the hashes and Git commit in the session manifest.

- Keep notebook use exploratory. Production acceptance metrics live in tested Rust or a pinned, scripted analysis environment invoked by the CLI.

- Test angle wrapping, quaternion normalization, frame transforms, clock discontinuities, missing samples, duplicate batches, and out-of-order arrival with fixtures.

# Phase 2 indoor mount control

## Connection discovery

Inventory the exact controller, firmware, ports, cables, and Mac device nodes before implementing motion. The preferred indoor path is Mac to a documented Celestron command endpoint through the hand controller or another supported bridge. Confirm commands and responses against current Celestron documentation and observed hardware behavior. Do not assume that every USB connector exposes the same protocol, voltage, or transport.

The iPhone should stream motion over Wi-Fi. iOS generally does not expose an iPhone as a generic USB serial accessory to a Mac app, and direct accessory communication may require ExternalAccessory or MFi support. USB tethering or a custom network path can be investigated later, but it is not a Phase 1 dependency.

## Mount command safety state machine

```text
DISCONNECTED → CONNECTED_READ_ONLY → ARMED → MOVING → STOPPING → ARMED
↘ FAULT_LATCHED ← any invariant violation
```
  
Only an explicit operator action enters ARMED. Any stale IMU stream, lost mount transport, command timeout, unexpected motion, limit breach, process shutdown, or emergency stop issues a stop through the safest available path and latches the fault. Re-arming is manual.

## Required interlocks

- Operator remains within reach of the mount power switch or a proven independent stop control.

- Start without the optical tube, accessories, or cables when practical; otherwise balance the mount and establish conservative mechanical clearance limits.

- Disable or remove any command that can initiate a goto during early tests. Allow only one axis, one direction, a low rate, and a short maximum duration.

- Reject commands unless IMU data is fresh, mount transport is healthy, the previous command is terminal, and the operator has armed the session.

- Auto-stop on duration limit, orientation envelope, rate envelope, acceleration anomaly, stale phone data, loss of acknowledgement, or measured motion opposite the requested direction.

- Record the stop request and all evidence. Never claim a stop succeeded only because the software sent a stop command.

- Route power and data cables with slack through the full permitted envelope. Use a spotter for the first tests on each axis.

## Synchronized command and IMU sequence

7.  Start a session, verify phone and mount metadata, load the approved safety configuration, and perform the stop-control check.

8.  Collect a stationary pre-roll long enough to estimate the current bias and verify the phone-to-tube transform.

9.  Create a command record before transmission. Record transmission, acknowledgement, and every mount response in Mac monotonic time.

10. Observe motion independently in the IMU stream. Stop at the planned short duration or earlier if an interlock fires.

11. Collect post-roll through settling. Add operator observations without altering event timestamps.

12. Close the trial, compute provisional metrics, and require an explicit review before the next rate, duration, or direction.

## Low speed test matrix

| **Test** | **Pattern** | **Primary results** | **Gate to continue** |
|----|----|----|----|
| Axis sign | One short pulse each direction, azimuth then altitude | Observed sign, cross-axis motion, onset | Correct sign and reliable stop |
| Rate response | Increasing low rates, one axis at a time | Steady rate, linearity, vibration, missed motion | No safety trip; response repeatable |
| Start and stop | Repeated identical pulses | Onset delay, stop delay, overshoot, settling | Timing uncertainty below response scale |
| Reversal | Positive motion, settle, negative motion | Dead time, lost motion, hysteresis, asymmetry | Short envelope and stable attachment |
| Backlash | Small alternating commands around a reference | Commanded motion before observed reversal, repeatability | Estimator validated in simulation and fixture data |
| Hold | Stationary intervals at several poses | Drift, creep, periodic error or vibration signatures | No uncontrolled motion |

## Backlash interpretation

An IMU can estimate angular lost motion after a direction change, but the result mixes drivetrain backlash, structural flex, attachment movement, controller ramping, static friction, and sensor noise. Label the first result as system reversal deadband unless an independent optical reference separates those effects. Report altitude and azimuth separately and include load direction, balance state, rate, pose, and approach history.

## Phase 2 acceptance criteria

- The mount simulator passes stop, timeout, stale-data, duplicate-command, opposite-motion, and connection-loss tests before hardware use.

- A hardware dry run proves that operator stop and power removal work independently of the Mac process.

- Every motion command has a complete lifecycle or an explicit unknown state. No command remains silently active after a timeout.

- Measured motion direction agrees with the configured axis mapping across repeated low speed trials.

- Reversal and settling estimates include uncertainty, sample gaps, clock uncertainty, pose, balance, load, and attachment revision.

- The same session replay produces the same acceptance decision and materially identical metrics within defined numeric tolerances.

# Phase 3 outdoor truth and ecosystem integration

## Camera and plate solving

Add an optical truth channel only after indoor command safety is stable. Time-stamp exposure request, exposure start and end when available, file receipt, and plate-solve result. A plate solve represents the camera orientation over an exposure interval, not an instantaneous IMU sample. Align it using the clock model and propagate that timing uncertainty into comparisons.

- Calibrate camera-to-phone and camera-to-mount transforms with multiple sky orientations rather than a single pose.

- Compare short relative slews and endpoint changes first. Later compare tracking, repeated approaches, and goto residuals.

- Store solver name and version, star catalog, image hash, field center, roll, plate scale, residuals, and solve quality flags.

- Use plate solves to correct or bound long-term absolute drift. Do not retroactively alter raw IMU data.

## ASIAIR integration

Treat ASIAIR as a later peer system. Begin with file and event import: FITS or image files, timestamps, target names, and plate-solve outputs that the user can export through supported mechanisms. If a documented API or supported integration becomes available, place it behind a separate adapter. Do not depend on undocumented endpoints for safety-critical stopping or command arbitration. Only one controller may own mount motion at a time, and ownership changes must be explicit and logged.

## Outdoor acceptance criteria

- Plate-solve observations link to images and exposure intervals with complete provenance.

- Camera, phone, and mount frame transforms are estimated from multiple orientations and validated on held-out observations.

- Relative IMU motion and plate-solve endpoint changes agree within a predeclared tolerance supported by Phase 1 and transform uncertainty.

- Control ownership prevents simultaneous motion commands from the diagnostic service and ASIAIR or another controller.

- Outdoor reports distinguish phone-relative, mount-commanded, and optically observed orientation.

# Milestones and deliverables

| **Milestone** | **Deliverable** | **Exit evidence** |
|----|----|----|
| M0 Foundation | Repository, ADRs, schemas, CI, simulator skeleton, safety case | Tests run on a clean Mac; schemas versioned |
| M1 Phone logger | Swift acquisition, local fallback, metadata screen, batch protocol | Recorded session with measured sample gaps and rate |
| M2 Mac recorder | Rust receiver, SQLite migrations, session CLI, replay | Round trip fixture; recovery after network interruption |
| M3 Bench report | Stationary, drift, indexed rotation, timing, attachment analyses | Phase 1 report and baseline acceptance decision |
| M4 Safe mount simulator | State machine, interlocks, live monitor, fault injection | Automated safety scenario suite passes |
| M5 Indoor hardware | Validated Celestron adapter and low speed test runner | Phase 2 report for both axes |
| M6 Optical truth | Camera ingestion, plate solve records, transform calibration | Held-out comparison report |
| M7 ASIAIR workflow | Supported import or adapter with ownership rules | End-to-end session without competing control |

## Suggested milestone order

M0 through M3 form the first useful release and should be completed before any physical mount motion. M4 is a separate safety gate. M5 begins with one axis, the lowest useful rate, and the shortest practical pulse. M6 and M7 remain optional until the indoor evidence supports them.

# Risks and mitigations

| **Risk** | **Consequence** | **Mitigation** |
|----|----|----|
| Phone heading disturbed by mount or room | False absolute orientation or apparent drift | Use relative rotations; characterize power states; record magnetic channel separately; use plate solving for absolute truth |
| Attachment flex or slip | Mechanical artifact mistaken for backlash | Rigid cradle, attachment ID, remove-and-replace tests, camera cross-check |
| Clock mismatch | Incorrect motor latency or reversal timing | Dual monotonic clocks, periodic exchanges, uncertainty, avoid overclaiming sub-uncertainty results |
| Protocol or firmware mismatch | Unexpected motion or ignored stop | Read-only discovery, documented commands, simulator, short pulses, independent stop |
| iOS suspension or thermal throttling | Gaps or rate changes | Foreground test mode, thermal and lifecycle events, local buffer, gap accounting |
| Two systems control the mount | Conflicting commands | Exclusive command lease and explicit ownership handoff |
| Analysis silently changes | Nonreproducible acceptance | Versioned config, locked dependencies, hashes, golden fixtures |
| Phone model assumptions | Implementation tied to an unverified sensor feature | Runtime capability discovery; metadata capture; no undocumented precision claims |

# Claude Code implementation prompts

Use these prompts sequentially. Give Claude Code this plan, the repository state, and the output of the prior milestone. Require it to stop after each prompt for review. Hardware commands remain disabled until the simulator and operator safety checklist pass.

## Prompt 1 repository foundation

Create a monorepo named celestron-workbench with ios/ImuLogger and a Rust workspace. Add ADRs for timestamp domains, coordinate frames, storage, network transport, and mount safety. Define JSON Schema for protocol messages and SQL migrations for the tables in the project plan. Add CI for Swift formatting and tests where available, cargo fmt, clippy with warnings denied, cargo test, schema validation, and migration tests. Implement no hardware motion. Finish with build and test instructions and a list of assumptions that still require physical verification.

## Prompt 2 Swift bench logger

Implement the iOS ImuLogger in Swift using Core Motion. Discover capabilities at runtime. Record the chosen attitude reference frame, requested interval, Core Motion timestamps, sequence numbers, attitude quaternion with declared ordering, rotation rate, gravity, user acceleration, and raw gyro and accelerometer when available. Keep callbacks short, use a bounded queue, count drops, write an NDJSON fallback, and stream versioned batches over Network.framework on trusted local Wi-Fi. Add a start and stop session UI, metadata view, marker button, connection status, effective sample rate, drop count, and local export. Do not claim a fixed maximum sample rate. Add unit tests for serialization, sequencing, quaternion normalization, and interruption recovery.

## Prompt 3 Rust receiver and storage

Implement the Rust Mac receiver with Tokio, Serde, tracing, and SQLite. Validate messages, acknowledge the highest contiguous sequence, store source and receive timestamps separately, detect gaps and duplicates, and support resend. Implement session create, stop, validate, export, and replay commands. Use one database writer with bounded channels. Add migrations, repository tests, corrupted-batch tests, network interruption tests, and a synthetic phone client. Preserve raw observations; do not interpolate them.

## Prompt 4 clock estimation

Add a periodic four-timestamp clock exchange between the phone and Mac. Fit a robust piecewise offset and drift model, store every exchange and model version, and attach aligned time plus uncertainty only as derived fields. Plot round-trip time, residuals, offset, and uncertainty. Test asymmetrical latency, outliers, phone reconnect, and monotonic clock discontinuity handling. Make analysis refuse latency claims finer than the clock uncertainty.

## Prompt 5 bench analysis

Implement a deterministic analysis CLI for stationary noise, observed sample intervals, gaps, power spectral density, Allan deviation, orientation drift, indexed relative rotations, endpoint return error, scale error, cross-axis coupling, settling, and attachment remove-and-replace repeatability. Use versioned YAML analysis configurations and fixed seeds for bootstrap confidence intervals. Generate Markdown, HTML, CSV summaries, and plots from a session. Include exclusions, hashes, software versions, clock uncertainty, and acceptance decisions. Add golden synthetic sessions for zero motion, known bias, known rotation, missing data, angle wrap, and quaternion sign equivalence.

## Prompt 6 mount simulator and interlocks

Implement mount-core and mount-sim without connecting to hardware. Model disconnected, read-only, armed, moving, stopping, and fault-latched states. Require a short command lease and one active axis command. Enforce low-rate and duration caps, orientation envelope, fresh IMU, transport health, acknowledgement deadlines, observed direction, and manual re-arm. Add deterministic fault injection for delayed acknowledgement, ignored stop, opposite motion, stall, disconnect, stale IMU, duplicate request, and process shutdown. Prove each scenario stops or latches safely in automated tests.

## Prompt 7 Celestron discovery

Create a read-only discovery tool for the exact Celestron connection path. Enumerate candidate serial or network endpoints, collect user-selected controller and firmware metadata, and capture raw request and response traces for documented non-motion queries. Do not send motion or goto commands. Produce a protocol compatibility report that maps each proposed command to a current authoritative reference or a clearly labeled hardware observation. Keep the adapter behind the mount-core trait.

## Prompt 8 indoor low speed runner

After the operator supplies the approved compatibility report and safety configuration, implement the Celestron adapter and an interactive test runner. Default to disarmed. Permit only one short, low-speed manual-rate command at a time and require explicit confirmation before each first hardware test. Log requested, transmitted, acknowledged, stopped, and observed motion events. Add a prominent stop action and auto-stop on every invariant in the plan. Implement axis sign, rate response, start-stop, reversal, backlash, and hold protocols, with review gates between trials. Do not add goto or unattended operation.

## Prompt 9 optical truth

Add camera file ingestion and a plate-solve observation schema. Wrap a user-selected installed solver rather than embedding undocumented services. Store image hashes, exposure timing, solver version, catalog, field center, roll, scale, residuals, and quality flags. Estimate camera-to-phone and camera-to-mount transforms from multiple observations and validate them on held-out samples. Compare IMU relative motion with plate-solve endpoint changes while propagating timing and transform uncertainty.

## Prompt 10 ASIAIR interoperability

Design an ASIAIR adapter that starts with supported file and metadata import. Document exactly which data the user exports and how it maps to the session schema. If a supported API is available in the actual environment, isolate it behind a trait and integration tests; otherwise do not guess endpoints. Implement exclusive control ownership so ASIAIR and this diagnostic service cannot both issue mount motion. Keep all safety stopping local to mount-core and independent of ASIAIR.

# Operator checklists

## Before every bench session

- Confirm attachment ID, phone orientation, reference frame, requested sample interval, available storage, battery and thermal state.

- Stabilize the fixture, note environmental changes, and record warm-up separately.

- Verify that local fallback logging is active and the Mac shows sequence, rate, gaps, and clock uncertainty.

- Create markers before and after each controlled movement and record the fixture reference independently.

## Before every mount session

- Inspect balance, clamps, clearance, tripod stability, cable routing, attachment security, and allowed motion envelope.

- Confirm the exact mount, controller, firmware, transport, axis mapping, rate cap, duration cap, and stop path.

- Prove the independent stop and keep the operator within reach. Begin disarmed and stationary.

- Leave the hand controller at its top-level screen and keep hands off its four arrow keys during runs: they move the mount even while the computer is connected, and that motion faults the safety checks. Navigate menus with SCROLL 6 and 9 (ADR 0010).

- Verify fresh IMU, valid clock model, live gap display, correct phone-to-mount transform, and stable pre-roll.

- Run one axis and one short pulse. Review the recorded stop and observed direction before continuing.

## After every session

- Stop and disarm the mount before closing software or disconnecting the phone.

- Finalize the session, checkpoint the database, export the immutable raw log, and compute hashes.

- Record anomalies and operator observations. Do not edit raw timestamps or samples.

- Run validation and generate the report. Mark the session accepted, rejected, or incomplete with a reason.

# Definition of done

The project is complete for its diagnostic purpose when a new operator can follow the documented setup, capture a bench or mount session, interrupt and recover safely, regenerate the same analysis from immutable data, understand the uncertainty of every reported metric, and distinguish commanded motion, phone-observed relative motion, and camera-observed absolute orientation. The system must make missing data, uncertain timing, unsupported hardware behavior, and safety faults visible rather than smoothing them away.

# Technical caveats

- iPhone inertial sensors are consumer components managed by iOS. Model name alone does not guarantee a documented sample rate, bias, noise floor, fusion algorithm, or calibration state. Measure the actual device and configuration.

- Relative rotation over short intervals can be useful even when absolute heading is poor. Gravity helps constrain roll and pitch under low acceleration; it does not establish yaw. Magnetic heading near telescope hardware is especially suspect.

- Core Motion attitude may reset or change behavior after interruptions or reference-frame changes. Detect discontinuities and segment the session rather than joining them silently.

- Phone-to-tube attachment error can dominate the sensor. Treat the cradle as part of the measurement instrument and version it.

- USB C on the iPhone does not imply generic serial access to Core Motion data. Wi-Fi is the straightforward first transport. Any later wired design must be validated against current iOS networking, accessory, entitlement, and hardware constraints.

- Celestron products and firmware may expose different command paths. Verify the precise hardware and current protocol reference before enabling commands. Never test an unverified stop command at a dangerous rate or duration.

- Plate solving provides an optical reference with its own exposure timing, flexure, solver, catalog, and transform uncertainties. It is stronger evidence for absolute sky orientation, not an error-free oracle.

- ASIAIR interoperability must use supported exports or interfaces. Keep control ownership and emergency stopping outside any undocumented integration.

# Public repository and private data

This repository is public. Real session data stays out of it. See [privacy.md](privacy.md) for what counts as private, where it lives, and the automated checks that enforce it. In particular, the session manifest's host information, device IDs, observing site coordinates, and attachment photos must go through the sanitizer before anything is committed under `fixtures/`.
