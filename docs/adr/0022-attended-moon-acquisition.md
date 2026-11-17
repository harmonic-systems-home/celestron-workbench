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
