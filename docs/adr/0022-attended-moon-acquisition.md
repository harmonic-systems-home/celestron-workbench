# ADR 0022: Attended Moon acquisition — camera-closed-loop, functionality first

**Status:** Proposed. Supersedes [ADR 0021](0021-moon-centre-by-survey.md); extends
[ADR 0019](0019-moon-mosaic-app.md); narrows [ADR 0005](0005-mount-safety.md) to
unattended motion.

## Context

The first field night on the scope (2026-11-16/17) showed that the blocker is not
tiling precision — it is **acquiring and holding the Moon at all**. The manual
workflow was slow and fragile:

- Spotting scope to get close, then a **manual spiral search with the hand
  controller** through the zoom eyepiece, finding the Moon by brightness and
  learning by trial which arrow key moves the image which way.
- Manual focus for the eyepiece while **constantly re-adjusting to track** the
  Moon, which crosses the camera's ~5′ short field in ~20 s.
- Swap the eyepiece for the camera, set shutter/gain in **ASICap**, refocus,
  still tracking by hand.
- Shut ASICap, start Moon Mosaic — but MM's live view stayed black (the ASI
  camera opens in one process; ASICap held it), so the Moon was never seen in MM.
- A **latched manual-slew runaway** (a separate hand-controller defect; move that
  won't stop) repeatedly lost the Moon, sending the operator back to the spotting
  scope to start over.

Operation is **attended**: the operator is present with hands on the clutches and
the power, and the equipment is light and slow (≤ 1 °/s) and cannot damage itself
at jog speed. ADR 0005 already states the software is not the primary safety
system — the operator and the power switch are. Its layer-3 motion-integrity
interlocks (OppositeMotion, overspeed, min-observed-fraction, overshoot) were
built to stand in for an **absent** operator. In attended use they were getting in
the way of the capabilities that matter — and they were faulting legitimate motion
(the backlash-canceling approach overshoot tripped OppositeMotion on ~half of tile
moves, the first-night fault).

## Decision

### 1. Functionality first, attended profile

For attended acquisition, rely on ADR 0005's **layer 1** (operator + power) and
**layer 2** (Celestron firmware limits), and run motion under a **minimal profile**
that omits the layer-3 motion-integrity interlocks. Prefer **self-terminating
gotos** over timed rate-slews: a goto ends itself, so the app's own motion has no
latched-runaway failure mode even before the hand-controller defect is fixed. Keep
only the positional/comms guards that don't impede the work: the altitude
floor/ceiling, command/ack/goto deadlines, and goto tolerance.

### 2. Moon Mosaic owns the camera

MM provides the **live view**, exposure/gain, and a focus aid itself; ASICap is
never in the loop. `SharedCamera` already shares the single open within MM. This
removes the ASICap↔MM handoff that lost the Moon. The ZWO binding (`ZWOCamera` /
`libASICamera2`, ADR 0019) is proven on hardware (it ran the O17 drain-pipe
measurement); what failed was live view wired through to the screen, not the
binding.

### 3. Camera-closed-loop acquisition pipeline

In order, each step usable before the next exists:

1. **Owned live view** (foundation): streaming frames on screen, with exposure,
   gain and a focus aid.
2. **Brightness acquisition**: find the bright blob / its centroid in the frame.
   Key property: a **brightness centroid is focus-independent** — an out-of-focus
   Moon is a large bright blob whose centroid is still the Moon's position. So
   acquisition, orientation and tracking all work before focus is set.
3. **Orientation calibration, with the Moon's drift removed.** The Moon drifts
   ~15″/s (about its own diameter a minute), so a commanded move and the sky drift
   are superimposed in the frame and must be separated. **First**, with the mount
   still, measure the blob's image-space velocity — that is the drift vector in
   pixels/s. **Then** command one small known move per axis and subtract
   drift × duration from the measured centroid shift, leaving the pure commanded
   response → a 2×2 image↔mount map that absorbs the alt-az geometry and the
   camera's rotation. This automates "which way does it move," done once at
   acquisition; the spiral and tracking both use it.
4. **App-driven search — two patterns, offer both.** The operator gets close
   with the spotting scope; the app then walks the remaining uncertainty,
   watching brightness, with an operator **"I see it"** flag. Stop → adjust
   gain/focus → **resume from the current position**. Operator-flag first
   (simple, robust); auto-detect later.
   - **Spiral** (`SpiralSearch`): an expanding square of small, self-terminating
     gotos — step-and-shoot. Best for a fine search over a small area.
   - **Raster** (`RasterSearch`): a serpentine of rows, run from the start's row
     outward (Amendment 3), **swept** at a moderate
     rate, grabbing frames as fast as the camera allows — fewer, longer moves
     cover a wide area quickly. Best when the uncertainty is large; it avoids a
     spiral's many short gotos.
   - **Detection beats the field.** The step (spiral) and row spacing (raster)
     can be set **wider than the camera's short field**, because the Moon's
     **glow shows in frame before its disk** — so coverage keys off the
     detectable width, not the field of view.
   - **Click to re-centre.** On either search, the operator can click the live
     image — *"I see something there"* — and the app converts the click's pixel
     offset to a sky/mount offset (via the camera scale), goes there, and
     **restarts a finer spiral centred on that point**. Coarse raster to find
     the glow, a click, then a tight spiral to land on the Moon.
5. **Brightness-centroid tracking**: null the drift measured in step 3 as a
   **feedforward** — the image-space drift vector, mapped through the orientation
   matrix into mount axes, is the rate the mount must hold to keep the Moon still —
   and **close the loop** on the residual centroid error. Holding the Moon centred
   lets the operator focus and set gain with it held still. Works out of focus, so
   it is available from the moment of acquisition. (The ephemeris drift, from the
   site and clock, is an independent cross-check on the measured drift.)
6. **Tune then mosaic**: focus/gain with the Moon centered, then the dead-reckoning
   mosaic (ADR 0019).

### 4. Relationship to prior decisions

- **Supersedes ADR 0021** (survey + circle-fit centering). The brightness pipeline
  acquires from a worse start (Moon not even in frame) and while out of focus; the
  survey/circle-fit is no longer the acquisition path. Its circle fit may still
  inform mosaic centering later.
- **Extends ADR 0019.** Acquisition and tracking are closed-loop on image
  brightness; the **mosaic capture** can remain dead-reckoning once the Moon is
  centered.
- **Narrows ADR 0005.** Its layer-3 interlocks govern **unattended/automated**
  motion. **Attended** acquisition runs the minimal profile with the operator in
  the loop.

### 5. The pipeline is target-agnostic

The primitives don't know about the Moon: the spiral is pure geometry, the blob
is the brightest region, the focus score is a gradient. So this is really an
**acquire-and-hold-a-bright-target** capability, with the mosaic as one
configuration on top:

- **Focus/orientation on the drainpipe.** The O17 drainpipe (a fixed daytime
  target out the office window) exercises the live view, blob, focus assist and
  orientation calibration on the bench — no Moon, no night, no field. Its one gap
  is drift: being terrestrial it doesn't move, so it can't test the
  drift-cancellation, which needs a sky target.
- **Planets, and a non-mosaic mode.** A planet is a small bright blob; the same
  acquire → orient → track works with tuned parameters (smaller blob, point-like,
  sidereal drift). "Acquire and track a target" is useful on its own, without a
  mosaic. Keep the primitives target-agnostic and expose the parameters.

## Consequences

- The latched-slew runaway (under separate investigation — electrical vs
  hand-controller firmware) stops mattering for app-driven motion, which uses
  self-terminating gotos, not manual jog. The operator rarely needs to jog the
  physical hand controller once spiral + track work.
- GUI and spiral logic can be built and tested against the **fake camera** with no
  safety-suite gate; attended hardware motion runs under the minimal profile with
  the operator present.
- The dead-reckoning **positional-envelope** interlock (previously drafted for the
  capture profile) is **deferred** to the unattended mosaic, where it belongs.

## Amendment 1 — search wiring, the altitude reference, and a test mode

Implementing the GUI drive (step 4) surfaced two concrete decisions.

- **The altitude reference comes from the rough aim, before Here.** The controller
  won't arm without a true altitude (the envelope's floor/ceiling need it), but a
  search runs *before* Here, so nothing has set one yet. The search sets it itself
  on the first arm: from the **Moon's computed altitude** for a Moon search (the
  spotting scope is already on the Moon, so the tube is within a degree of it — good
  enough for the envelope), or from a stated **test altitude** for a terrestrial
  target. Once set, Here and the survey refine it as before. `searchSpiral` /
  `searchRaster` take an optional `referenceAltitudeDeg` and set it only when the
  mount reports none.
- **A test mode for the bench.** A first-class toggle runs the whole search-and-focus
  path against a **fixed daytime target** (the O17 drainpipe) with **tracking off**:
  it exercises both search patterns, click-to-recentre, the live view and the focus
  assist on the bench, no Moon or night needed. Because a daytime drainpipe isn't a
  bright blob against dark sky, **automatic acquisition is disabled in test mode** —
  the operator ends the search with "I see it." This is the drift gap of §5 made
  concrete: everything but drift-cancellation (which needs a moving sky target) is
  testable here. The reference altitude above is what lets it arm indoors.
- **The simulator dry-runs the whole UI.** In simulate mode the fake sky keys
  off the real (simulated) mount position with a target **offset from where the
  tube starts** — out of frame at first — so the search genuinely hunts and
  click-to-recentre visibly walks it in, no scope needed. The Moon drifts with
  the ephemeris (so Here, calibrate and the mosaic rehearse unchanged); the
  test-mode drainpipe is a fixed, non-drifting stand-in. This replaces the
  earlier behaviour where the fake Moon sat centred until Here.

## Amendment 2 — converge onto the disk, and no plan without a centre (2026-11-18)

The 2026-11-17 capture planned 18 tiles on empty sky and left ~15 Moon tiles
unplanned: the grid sat ~0.7 Moon radii high. The operator saw the cause: the
search stopped at the first hint of brightness. A frame passes `found` when ≥10%
of it is above 30% of its peak, and the Moon's glow or a sliver of limb along one
edge does that. Here was set there, Find centre never succeeded (every plan tile
was saved `lit: true`), and the plan was centred on Here.

- **Converge after the sighting.** An automatic search (not test mode, not "I see
  it") treats the sighting as a glimpse and steps onto the disk. Each step is one
  lean search goto (§3, Amendment 1) that moves the lit region's centroid to the
  frame's centre. Each step is capped at one frame's short side, with at most 12
  steps and 1° of sky from the sighting. It stops when the frame is on the disk:
  ≥80% lit, or ≥50% lit with the centroid within a tenth of the frame of the centre.
  "Lit" here is above 15% of the peak. At 30%, maria fall below the line: real
  2026-11-17 frames wholly on the disk read 47–100% at 30%, but 95–100% at 15%,
  while limb slivers read 10–35%.
- **The orientation is learned, not assumed.** The search runs before calibration,
  and the pre-calibration guess (x right → azimuth, y down → lower altitude) is
  mirrored by the star diagonal: 2026-11-17's calibration has x reversed. A step
  that loses ground (less lit, the centroid no nearer the centre) is undone and the
  next orientation tried: as guessed, mirrored left-right, mirrored top-bottom,
  turned 180°. The one that works is kept for the rest of the session's
  pre-calibration moves, including click-to-recentre. Four failures in a row end
  the converge, and the app tells the operator to centre the Moon by hand.
- **No silent plan without a centre.** `makePlan` throws unless Find centre has
  succeeded or the caller passes `allowWithoutCentre`. The app warns on the first
  press and plans around Here only on a second press within 30 s.

All of this stays within the attended minimal motion profile: short,
self-terminating gotos with the operator at the mount.

## Amendment 3 — the raster searches from the start outward (2026-11-18)

The raster began at the box's bottom corner (−W, −H) and worked up row by row, so
it searched the least likely place first: the Moon is almost always at or near
where the spotting scope left the mount. Its first move was also its longest.

- **Rows run from the start outward**: the start's row, then one row up, one
  down, two up, two down, and so on. There is always a row through the start.
- **The start's row begins at the start.** The first frame is taken before any
  move. The row sweeps out to −W, jumps back (half a row, the only ground crossed
  twice), and sweeps out to +W. Each later row begins at the end where the last
  one finished, so rows still alternate direction with no return pass. Each place
  is shot once.
- The row-to-row altitude jumps grow (1, 2, 3, … spacings). That costs a little
  altitude travel on a full, fruitless search. In the common case the search ends
  in the first two or three rows: in the simulator, a target one row above the
  start is found in 10 stops instead of 33.

The spiral already started at the current position, so it is unchanged.

## Amendment 4: in attended operation, faults don't end the run (2026-11-19)

On the night of 2026-11-19 the hand controller stalled again and again (low battery,
about 9.65 V). Each stall latched a fault (a command not sent within 1 s, or
position reads gone stale), and each latch ended the step. A single fault partway
through a mosaic ended the run. The operator watches the mount and judges there is
no danger, so missed feedback must not stop the operation.

- **No software limits in attended mode.** Moon Mosaic opens its session with the
  altitude envelope at −90° to 90°, and the send, acknowledgement and position-age
  deadlines at 10 s. What protects the mount is physical: the operator within reach,
  the power switch, and the mount's own firmware limits. This replaces the
  build spec's "keep the altitude and deadline guards" for attended operation.
- **Faults clear themselves, and the move is retried.** When a fault latches, Moon
  Mosaic waits up to 90 s for the hand controller to answer and the mount to read
  still. It then resets, re-arms, and retries the interrupted move from a fresh
  position, up to 5 times. The operator's emergency stop is never undone.
- The shared controller is unchanged, so unattended and automated motion stays
  gated as before.

## Amendment 5: tracking (2026-11-19)

Without tracking, the Moon drifts about 15″ a second. Hold re-aimed with a goto every
10 s, so the live image jumped constantly, and every tile's video smeared by about
180 px. Tracking now runs the Moon's own motion on both axes.

- **How:** the session's `track` request sends a variable-rate move to each motor
  controller (`P 03 dev 06|07`, 0.25″/s steps). Both axes run at once, at rates
  Moon Mosaic computes from the ephemeris (`target` over ±15 s). Tracking ends with
  `T 00` and fixed rate 0 on both axes, which is the existing stop. Any arm (a move
  about to start) and any stop end it first.
- **The controller stays out of it:** while tracking, the session disarms the
  controller and doesn't feed it positions, so the steady motion isn't taken for
  unexpected motion. The adapter keeps reading positions during tracking
  (`set_read_while_moving`).
- **Where it's used:** Hold makes one goto, then tracks, with a small correction (at
  most 7″/s, over about 20 s) toward the aim. It makes a new goto only if more than
  about 2′ off, or after a pan. Each tile's video is tracked at the plain rate. The
  next tile's goto takes over.
- **What's left open:** a goto made while tracking was running relies on the arm
  having stopped it first. The rate quantisation (0.25″/s) and ephemeris error are
  absorbed by Hold's correction. Closed-loop tracking on the image centroid (step
  5 above) is still to come.
- **The pan replaces the hand controller:** Hold's aim can be moved with pan buttons
  in the app, a quarter or a twelfth of a frame at a time. On 2026-11-19 the hand
  controller's arrow keys fought Hold and twice ran away.

## Amendment 6: calibration by drift and tracked moves (2026-11-19)

The two-goto calibration was unreliable. Tonight it gave 0.33–0.38″/px against a
true 0.281″/px (measured from the stitched mosaics), and camera angles from −8.7° to
+3.4°. The cause was frame matches that under-measured the shift, partly locking onto
the sensor's fixed pattern at zero. That bad scale made the plans too small, threw
off Find centre's map of the survey, and misplaced the tiles.

- **Drift gives the scale and the angle.** From the Moon held at the aim, tracking
  pauses for 6 s, and frames on a 1 s schedule follow its drift (about 50 px per
  step at 15″/s and 0.28″/px). The ephemeris gives the Moon's motion exactly, so
  the image's motion fixes the scale and the camera's turn. No focal length is
  needed, so Barlows, reducers, no diagonal and other cameras all work. Matches
  ignore peaks near zero shift, where the fixed pattern sits (`Registration.shift`,
  `minShift`).
- **Two tracked moves give the second direction.** After a re-centring goto to
  where the ephemeris puts the aim, the mount tracks a little faster on one axis
  for 4 s. The Moon stays put apart from the commanded offset, with no goto, no
  settle and no drift between the two frames. This is done once in azimuth and
  once in altitude. Together with the drift, that settles mirroring (a star
  diagonal).
- **Fit and check:** the map is the least-squares fit to all three measurements.
  Each must agree with it within 15%, or the attempt repeats (up to 3 times). The
  scale is logged against the focal-length estimate, with a "Barlow?" note if they
  differ by more than 25%. It is never rejected on that alone. Every frame,
  shift, Moon motion and residual is saved in `setup-<time>/calibration/`.
- **In the simulator:** with a fake camera at twice the focal-length scale (like a
  2× Barlow), the drift alone recovers 0.600″/px against a true 0.6. The angle
  comes out at 20.1° against 20°, the residuals at 0–2%, and mirroring is
  detected both ways.

## Amendment 7: track first, then a guided flow (proposed, 2026-11-20)

Status: **proposed**, for review before any code. It comes from a design discussion
the morning after the 2026-11-19 runs. That night, about half the observing time
went into searches. Hand-controller runaways lost the Moon twice. A symmetric plan
missed an egg-shaped gibbous Moon, and Hold's correction fought the operator's
nudges.

### Priorities

In order: **safety, correctness, accuracy, timeliness.** Each design choice below is
weighed in that order, but safety is balanced against timeliness, not bought at
any cost.

- **What safety means here:** amendment 4 stands. No fault latches, and missed
  feedback never stops the run. Safety is instead a limit on what the app itself
  commands:
  - a cap on rate-move speeds (about 2°/s; sweeps at 1°/s);
  - a cap on net movement: app-commanded moves never take the aim more than a set
    distance from the Moon's predicted position (beyond the search area), except a
    slew the operator asks for explicitly.

  A command over a limit is refused with a message. It doesn't latch, and nothing
  already running stops. The operator's hand-controller moves are never limited.
- **Sun avoidance** (daytime and twilight). Today it is one check at Here: the Moon
  at least 40° from the Sun, whatever the Sun's altitude, and nothing checks where
  the scope actually points. With Here gone, it changes to:
  - **The scope's pointing, not the Moon's:** every app-commanded move's path and
    target, and the whole search area, keep at least the minimum separation from
    the Sun (40° by default).
  - **Only while the Sun is up:** active while the Sun's altitude is above about
    −2° (its disk plus refraction). After sunset it is off by itself, so a thin
    crescent in twilight needs no override.
  - **Override** for sunrise and sunset: an explicit, confirmed setting for this
    session (the separation lowered, or off), logged, and reset when the app
    restarts.
  - Hand-controller moves can't be refused. If the pointing comes within the
    separation, the app warns at once. Cover the spotting scope in daylight: it's
    an eye hazard the app can't guard.
- **Correctness** before accuracy: the right tiles in the right places, with the
  right orientation, before sub-arcsecond refinement.

### Tracking is the baseline

- **Track / Stop Tracking** is one toggle, right after Connect. It needs only the
  ephemeris, the site and the clock, not Here. The Moon's rates in azimuth and
  altitude don't depend on where the encoders think the mount points. Point with
  the spotting scope, press Track, and the Moon stays put.
- Track first sends `T 00` (the hand controller's tracking off, so the two never
  overwrite each other's rate), then sets the variable rates. `T 00` also cancels
  our own rate, so it is never sent while tracking runs, except by Stop Tracking.
- **Moves add to tracking; they don't replace it.** A short move (nudge, pan,
  search step, tile-to-tile step) is extra rate on both axes for T seconds, in the
  ratio Δaz : Δalt. Both motors start and stop together, the path is straight on
  the sky (cross-coupled), and tracking resumes the instant the extra rate ends.
  Long slews still use the firmware goto, and tracking resumes after them. Today's
  gotos run azimuth to the end, then altitude: an L-shaped path.
- The 0.05°/s cap on tracking rates in the session rises to cover rate moves (about
  1–2°/s; the protocol allows about 4.5°/s). Encoder reads close the loop, with a
  small correction at the end of a move.

### Follow mode, nudges, Stop and Undo

- **Follow** (the default): plain tracking, no correction toward a stored aim.
  Wherever a nudge leaves the scope, it stays, as with the hand controller.
- **Nudges come from the hand controller or the app.** A keypad move is the motor
  controller's fixed rate. A fixed rate 0 (a key release) does not cancel the
  variable rate (docs/observations.md, O1), so tracking should carry on after a
  nudge. What a *nonzero* fixed rate does while a variable rate runs (adds to it,
  overrides it, or is ignored) has not been observed. The hand controller's own
  tracking and nudges suggest it works, but the simulated hand controller assumes
  it is ignored. This is the first bench test.
- **The app sees every nudge.** A nudge begins when the encoders leave the tracking
  path, and ends when they've been back on it for about 0.5 s. Its start is pushed
  onto an undo stack.
- **App nudges:** ¼ frame per press, or ⅟₁₂ frame with Fine, with press-and-hold to
  keep moving. Before Orient Camera the buttons work in mount axes; after it, in
  the camera frame (▲ moves the image up). The app ends its own nudges, checks on
  the encoders that the motor stopped, and sends the stop again if not.
- **Stop** ends a nudge, from either source: fixed rate 0 on both axes, never
  `T 00`, so tracking keeps running. Nothing is stopped automatically: the
  operator may make large moves on purpose, for example to adjust the spotting
  scope. Whether our fixed rate 0 also ends a hand-controller runaway is a bench
  test.
- **Undo** returns to the position before the last nudge *relative to the Moon* (a
  goto to that sky offset at the current time, not the raw encoder position, which
  the Moon has left) and resumes tracking. It can be pressed repeatedly. A runaway
  and the operator's opposite-key correction usually take two Undos.
- **Lock** is used inside Orient Camera, Orient Moon, Calibrate and capture. It
  corrects drift toward a stored aim. A nudge moves the aim instead of being
  fought.

### The flow

A strip along the top of the window shows the steps and where the session is in
them. Steps can be repeated; Track/Stop Tracking, Stop, Undo, the nudge buttons and
Calibrate are available throughout.

1. **Connect.**
2. **Track.**
3. **Find:** the search, as continuous sweeps (below). Landing on the disk ties the
   encoders to the sky, so there is no separate Here step.
4. **Camera settings and coarse focus.** The app frames the bright limb about 25%
   from one edge of the frame, with the rest filled with Moon features, so the
   overall look can be judged. **Auto-set** sets exposure and gain from that
   frame: the brightest lit area just below clipping (well under 0.1% of pixels
   saturated), with the shortest exposure that allows it, to freeze the seeing,
   and gain making up the rest. The operator can override either. Today both are
   manual. Coarse focus is done when the Detail readout turns green.
5. **Orient Camera:** tracking pauses and the Moon drifts through the field for
   about 6 s, giving the scale and the camera's angle (amendment 6). One small
   automatic nudge then settles mirroring. Undo returns to the Moon position
   before the drift and resumes tracking. The nudge buttons switch to the camera
   frame.
6. **Orient Moon:** Find centre, extended to rotation. The Moon's rotation on the
   sky comes from the ephemeris (the position angle of its axis plus the
   parallactic angle), and the bright limb's direction comes from the phase. So
   this measures the centre and *checks* the rotation and mirroring against the
   prediction, flagging a disagreement. The phase (lit fraction, bright limb,
   terminator ellipse) is a prior for the survey fit.
7. **Fine focus:** **Go to Terminator** moves to where the terminator crosses the
   axis through the bright limb, R·cos(phase angle) from the centre on the dark
   side. **Go to [crater]** chooses from a small catalog (about 30 prominent
   craters, with lunar coordinates) one about 5–15° inside the terminator on the
   lit side, where the shadows are long. That needs the Moon's physical ephemeris
   (libration and the Sun's position over the Moon, Meeus ch. 53). **Go to Limb**
   (about one frame inside the bright limb) is for checking exposure.
8. **Recheck:** this is a Celestron SCT, which focuses by moving the main mirror.
   That changes the focal length (the scale) and shifts the image sideways. After
   fine focus, a short drift re-measures the scale and a quick survey re-measures
   the centre. Rotation is unaffected. Finishing the focus by turning the knob the
   same way keeps the mirror's shift consistent.
9. **Plan:** shaped by the phase, not symmetric.
10. **Start:** unidirectional rows (below). Afterwards, back to Follow.

### Orientation at full Moon

Near full there is no terminator, and the bright limb's direction is undefined.

- **The camera's orientation doesn't need the Moon's features:** Orient Camera gets
  it from the drift and the mirror nudge, at any phase. The Moon's rotation on the
  sky comes from the ephemeris (the position angle of its axis plus the
  parallactic angle). Together they predict the Moon's rotation in the image.
- **The check uses an albedo map:** the same LRO albedo map is rendered as the Moon
  looks tonight: libration, rotation, phase (simple lighting). The survey frames,
  or a live frame, are correlated against it. Maria against highlands contrast
  most at full Moon, so this check is strongest just when the terminator isn't
  there.
- **The same rendering serves every phase:** it gives the centre and rotation from
  the features, improves Orient Moon's fit near the limb, and places Go to
  [crater] targets.

### Readouts on the preview

- **Light:** is the Moon in the frame? This is the search's detector (below).
- **Detail:** "can orient from here". It measures how much the band-passed frame
  gives the frame matching to lock onto, the same quality the drift and
  calibration need.
- **Sharpness:** a focus number that rises as focus improves, for coarse and fine
  focus.

### Search by continuous sweeps

- Each raster row is one azimuth rate move with the camera streaming, on top of
  tracking, so the pattern travels with the Moon. Azimuth spans are scaled by
  1/cos(altitude), so the pattern is even on the sky.
- The Moon (31′, plus glow) is far larger than the field (about 6′ × 3.4′), so
  rows can be about 0.4° apart. At 1°/s with a 2 ms exposure, the blur is about
  7″, and at 30 frames per second the disk spans more than a dozen frames. A ±2°
  area takes about a minute.
- Each frame gets a timestamp, and the encoder position at that moment is
  interpolated. On a sighting, the mount slows, comes back to that spot and
  converges onto the disk.
- **One detector, day and night:** each frame is compared with the sky level the
  sweep has seen so far, and checked for texture or a sharp limb edge. Over a
  dark sky that's a large jump in brightness. In daylight, near the Sun, the sky
  can be almost as bright as the Moon, but it is smooth and changes slowly. With
  this detector, Test mode no longer needs auto-detect turned off. Today it is
  off there, and on at night: on 2026-11-19 it reported "target in view" after
  16–53 stops.

### Capture in one direction

- Every row is captured moving the way the Moon drifts in azimuth, and rows follow
  in the direction it drifts in altitude. Tile-to-tile moves add rate in the
  direction tracking already turns each motor, so no motor reverses within a row:
  no backlash at all, not just a consistent finish.
- The only reversal is the flyback to the start of the next row. It ends with an
  approach in the tracking direction before that row's first tile.
- Today's capture is serpentine. Each goto already finishes in the Moon's drift
  direction (overshooting and coming back when needed), but the motors reverse
  every row.

### Calibration that keeps improving

- **Calibrate** stays as a button. It goes to a high-Detail spot (near the
  terminator, inside the lit side, no sky in the frame; not flat maria or the
  limb) and repeats the drift and the tracked moves.
- Every app nudge is also a known move with a measured image shift. Such a
  measurement updates the map only when the frame match is strong and it agrees
  with the current map within a tolerance. The map updates gradually, as a
  running fit, and is never replaced by one measurement. Rejected measurements
  are logged. Every map is logged, so a bad one can be reverted.
- The same measurements give the backlash on each axis.

### Time budget

Each step has a designed duration. The app logs each step's start, end, estimate
and actual time, and the difference, in `records.ndjson`, with a summary at the end
of the session. The estimates assume the 2026-11-19 search area (±2.8° in azimuth,
±1.7° in altitude) and the Moon at about 50° altitude.

| Step | Estimate | Basis |
|---|---|---|
| Connect | 10 s | |
| Track | 1 s | |
| Find | 50 s typical, 100 s worst, plus 10 s to converge | 9 rows 0.4° apart, 8.7° of azimuth travel each at 1°/s, 2 s per turnaround. On 2026-11-19 stop-and-shoot searches took 30 s to 2 min each, and several per attempt. |
| Camera settings | 10 s auto-set | plus coarse focus by hand: 2–3 min |
| Orient Camera | 20 s | 6 s drift, the mirror nudge, Undo |
| Orient Moon | 60 s | to be measured |
| Fine focus | 5 s per goto | plus focusing by hand: 2–5 min |
| Recheck | 30 s | |
| Plan | 1 s | |
| Start | about 5 s per tile plus 5 s per row | a 53-tile, 8-row plan in about 5 min. On 2026-11-19 a 53-tile run took 11 min 14 s (12.7 s per tile, 3 s of it video), because of sequential gotos, approach legs, touch-ups and settling. |

Apart from focusing by hand, a session from Connect to a finished mosaic should
take about 8–9 minutes.

- **During capture:** a time-remaining readout, from the tiles and rows left at the
  measured rate so far (the estimate until the first row is done).
- **When capture finishes:** the window switches to the mosaic preview.

### Future: autofocus

A focus motor may be added. Autofocus would be a step after Orient Moon: go to a
terminator crater, then sweep the focuser through focus while logging the
Sharpness readout. Fit the curve's peak, and finish the approach in a fixed
direction (the SCT's mirror). Recheck runs after it as it does after manual focus.
The same routine could coarse-focus first from the Detail readout. To do: choose
the focuser and its protocol (Celestron's own focuser sits on the AUX bus), and
give the simulator a focuser.

### Simulator

The simulated camera is the key to testing every step before the next clear night.
It could well be more code than the app.

- **Three modes:**
  - **All simulated:** the simulated mount and the simulated camera, for headless
    test runs.
  - **Real mount, simulated camera:** the camera is "pointed" by the real mount's
    encoders, with the Moon moving across the sky per the ephemeris and a random
    offset between the encoders and the sky. This tests real tracking, hand
    controller nudges, app nudges, Stop, Undo, sweeps and capture moves together,
    in daylight or cloud. It moves the real mount, so it is attended, like any
    session.
  - **All real.**
- **Scenes from real images:** our mosaics (at the native 0.28″/px), DWARF stacks,
  other DWARF images, and downloaded images. Some downloaded images have more
  detail than ours, and can be scaled down to 0.28″/px as references. DWARF images
  have less detail than our final images, but probably enough to tell coarse focus
  from fine. The test set is chosen especially to cover **many phases**, plus
  daytime Moons. Each scene is prepared once: the disk's centre and
  radius are fitted (as in the 2026-11-19 overlay analysis), and the bright limb's
  direction, the lunar north and the time taken (if known) are recorded. Scenes
  live in the private data folder, never in this repo. Downloaded images keep a
  note of their source and licence. A scene enlarged beyond its own resolution has
  no fine detail, so fine-focus tests use our mosaics or detailed downloads.
- **Rendered scenes:** a global albedo map and elevation model of the Moon (NASA's
  LRO mosaics, as in NASA's "CGI Moon Kit"), rendered for a chosen time. The
  libration, the rotation on the sky and the Sun's direction come from the
  ephemeris. This gives any phase, at any resolution, with shadows from the
  terrain, and the ground truth is exact. Real images keep the real optics and
  seeing; rendered scenes cover every phase and geometry.
- **Wide sky view (testing):** a second window showing the search area, the true
  Moon (in the simulator) or the predicted Moon (on the real sky, once Find has
  tied the encoders to it), and the camera's footprint and its path. During a
  search, the camera's sweep across the area is visible.
- **Phase:** a scene's own phase is fixed. Either pick a scene near the
  ephemeris's phase, or turn the scene so its bright limb matches the ephemeris,
  or deliberately mismatch them to test Orient Moon's disagreement check.
- **Randomized scenarios, from a seed:** the Moon's rotation and mirroring in the
  camera, the starting point (somewhere in the search area but not in view), the
  initial focus and exposure, the seeing, and clouds. The seed is logged, so a
  failure can be replayed exactly.
- **The camera model, in order:**
  1. Sample the scene at the pointing, scale, rotation and mirroring, with motion
     blur during the exposure.
  2. Defocus (a disk-shaped blur that grows with the focus error), plus seeing (a
     blur that changes frame to frame, with image motion, so that selecting the
     best frames does something).
  3. SCT focus effects: the scale changes and the image shifts sideways as the
     focus moves.
  4. Sky: night, with a glow around the Moon, or a daylight sky gradient; and
     clouds as moving attenuation.
  5. Exposure and gain into noise, then 8 bits with clipping: under- and
     over-exposure are tested this way.
  6. The sensor's fixed pattern and hot pixels. The fixed pattern misled the frame
     matching on 2026-11-19.
- **Manual focus controls (simulated):** a focus knob in the app, coarse and fine,
  standing in for the SCT's knob. Its position sets the defocus, the scale change
  and the mirror shift, with the mirror's lag and jump when the knob reverses
  direction (mirror flop). Its true best focus is random per scenario. The same
  interface serves a future motor focuser, so autofocus can be developed against
  the simulator.
- **Optics are configurable:** focal length, Barlow or reducer, with or without the
  star diagonal (mirroring), and the camera's sensor (pixel size, width and height,
  frame rate, bit depth). So another camera with a wider field, or the scope
  without its diagonal, is simulated by choosing a different setup.
- **A simulator window:** its own controls, separate from the app's, for the
  things the simulator stands in for: the focus knob, the optics and camera
  setup, the scene and phase, seeing, clouds and sky, the seed, and fault
  injection (a stuck keypad move, a dropped link). It also has the wide sky view,
  with the true Moon and the camera's footprint. The app's own buttons (Track,
  nudges, Stop, Undo, Orient Camera, and so on) are tested against it.
- **Real time:** streamed frames at the camera's real frame rate (30 fps or more),
  timestamped, for sweeps. Today's fake camera takes seconds per frame. The new
  one warps a prepared, multi-resolution scene on the GPU (Core Image or Metal)
  instead of drawing craters per pixel.
- **Ground truth:** the simulator knows the true centre, rotation, scale, focus and
  exposure. A scenario runner drives the whole flow and scores each step (centre,
  rotation and scale errors, exposure, the share of the disk the mosaic covers),
  along with its time against the budget.

### Still open

- **Altitude near the meridian:** the Moon's altitude rate passes through zero and
  changes sign there. And the tube's weight may load the altitude gears one way
  whatever the motion. Check both in the traces.
- **Interruptions:** what happens to a capture or a sweep interrupted by a fault,
  a nudge or a Stop.
- **The simulator:** which pieces to build first.
- **Build order:** the simulated camera first: it needs no telescope. Then a
  bench test of the keypad behaviour, then Track-first in the app (Track, Follow,
  nudges, Stop, Undo, the progress strip, timing), then the sweep search, Orient
  Camera and Orient Moon, then camera settings and focus, then capture in one
  direction.
- **A keypad press while our variable rate runs:** whether it adds to the rate,
  overrides it or is ignored (above). The simulated hand controller needs keypad
  moves and runaways once this is known.
