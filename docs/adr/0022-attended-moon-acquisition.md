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
   - **Raster** (`RasterSearch`): a serpentine of rows **swept** at a moderate
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
