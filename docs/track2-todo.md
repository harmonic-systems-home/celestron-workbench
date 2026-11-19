# Track 2 — Moon Mosaic app fixes

Derived from the 2026-11-17 capture + off-line recovery session (see the private
data folder `2026-11-17_2049_Moon-Mosaic/` and memory `mosaic-processing-pipeline`).
Goal: future capture nights produce clean, complete, correctly-oriented mosaics
with little or no manual recovery.

**Safety constraint (CLAUDE.md / ADR 0022):** automated/unattended mount motion
stays disabled until the simulator safety suite + operator checklist pass.
Anything here that moves the mount (tracking, verify-move, pan) runs attended,
operator-present, under the minimal motion profile.

## P1 — highest leverage (do first)

1. **Enable mount tracking during capture.**
   - Why: the mount was NOT tracking; the Moon drifted ~64 px/s (~178 px within
     each 3 s tile). That forced per-tile align-and-stack and threw off the
     mount-based tile positions (which needed ~10% corrections).
   - Done when: the mount tracks during capture (lunar rate ideal; sidereal alone
     removes ~97% of drift); intra-tile drift is a few px, not ~180.

2. **Center the plan on the Moon.**
   - Why: the grid sat ~3 rows too high. 18 of 47 tiles were aimed at empty sky
     above the Moon (and caused false "soft" rescan prompts), while ~15 Moon tiles
     along the bottom limb were never planned. Only ~60% of the disk's tiled area
     was covered.
   - Done when: every planned tile contains Moon and the lit disk is fully covered
     at the configured overlap. Report empty-box and missing-tile counts after
     planning as a self-check.

2b. **Search from the current row outward, not from the far edge.**
   - Why: the raster/survey search currently drives to the far edge of the scan
     range and works up/across — it searches the *least likely* location first. The
     Moon is almost always at or near the current pointing.
   - Fix: start at the center (current) row/position and alternate outward — up,
     down, up… — so the most likely cells are covered first. (Likely in
     `RasterSearch.swift` / `SpiralSearch.swift`.)
   - Done when: the search begins at the current row and expands symmetrically; for
     the common case (Moon near current pointing) acquisition time and total mount
     travel drop markedly, with less exposure to overshoot/runaway.

2c. **Don't stop the search at the first glimmer — converge onto the disk.**
   (Operator observation, 2026-11-18. This is the likely root cause of #2.)
   **Status: implemented 2026-11-18, ADR 0022 amendment 2. Simulator-tested; awaiting a
   night on the real mount.**
   - Why: the search ends at the first stop where `peak ≥ 120` and ≥10% of the frame
     is above 30% of that peak (`AppModel.runSearch` `found`;
     `MosaicSession.walk`). The Moon's glow, or a limb sliver along one edge,
     passes that test, so the search stopped off the disk. Here was then set there,
     and the plan is centred on Here. Find centre never succeeded that night: every
     plan tile was saved `lit: true`, which only happens without a centre fit. So the
     grid was centred on the glow, ~3 rows (~0.7 Moon radii) too high.
   - Fix: treat the current hit as a *glimpse*, then converge. Repeatedly re-centre
     on the blob centroid (which, at a glimpse, sits at the frame edge and points
     toward the Moon), each step a bounded, self-terminating goto of at most about
     one frame. Stop when the frame is on the disk: lit fraction ≥ ~0.8 and the
     centroid near centre, or a step cap is reached (then report and stop). Report
     the final lit fraction.
   - Guard: `makePlan` should refuse, or warn loudly, when Find centre hasn't
     succeeded (`centreFit == nil`), rather than silently centring the grid on Here.
     Or run Find centre automatically after a converged search.
   - Done when: in the simulator, a search started with the Moon just off-frame ends
     with the frame on the lit disk (not on glow or a limb sliver), and planning
     without a centre fit is blocked or clearly flagged.

## P2 — correctness / data integrity

3. **Non-destructive rescan.**
   - Why: the auto-rescan (triggered by the false soft flags) re-aimed to the wrong
     area and OVERWROTE the originals (tiles 38, 42) — permanent data loss, an
     unfillable hole in the mosaic.
   - Done when: a rescan writes a new file and never overwrites an original until a
     replacement is confirmed better.

4. **Verify move before capture.**
   - Why: approach-overshoot and wrong-row aiming went undetected at capture time.
   - Done when: after each slew, confirm the frame is where expected and contains
     Moon before capturing.

5. **Save-at-capture metadata.**
   - Why: the recovery was forensic. There were two timestamp clocks, and these were
     missing: shutter, gain, app version/build, tracking state, a single clock,
     ephemeris orientation, setup time.
   - Done when: the session records shutter, gain, app version+build, tracking
     on/off, per-tile timestamps from ONE clock, site, and the survey's `litSky` +
     Moon-center (needed for #6; this session saved all tiles `lit:true` by default).

6. **Auto-orient to sky (naked-eye / zenith up).**
   - Method (validated this session): target = bright-limb position angle (Meeus
     ch.48) minus parallactic angle (Meeus ch.14), in the gravity frame; source =
     the Sun direction in the image, taken from the app's full-disk survey lit
     region (unbiased — `MoonCentre`/`Mosaic.markLit`) or from the calibration
     matrix mapping the ephemeris Sun vector; plus a **"mirror/diagonal used"
     setting (default true for this rig)** → a flip. For 2026-11-17 the result was a
     simple vertical flip.
   - Do NOT measure the Sun direction from an incomplete mosaic's limb/brightness
     (it biased ~90°). Use expected lit fraction/shape (from elongation) as a sanity
     check. Do NOT write an EXIF Orientation tag on output (it rotates previews).
   - Done when: the app emits a correctly-oriented final without manual steps.

## P3 — quality / UX

7. **In-app lucky stacking with zero-fill alignment.** Per-tile stack (~15× SNR):
   rank by sharpness, keep best ~60%, align to the mid frame with **bilinear
   zero-fill + coverage** (NOT Fourier phase-ramp — circular wrap corrupts tile
   borders and that single bug produced ALL the mosaic seams).
   - Update 2026-11-18 (v2 re-process): keep the best **~20%** (ranked by band power
     at ~2–6″ periods) and wavelet-sharpen the composite. That is clearly sharper on
     a seeing-limited night. Local multi-point alignment gained nothing.
   - **Alignment must be band-passed.** Plain whitened phase correlation locks to
     the sensor's fixed pattern at (0,0) for many frames in limb and sky-heavy tiles,
     giving a ghost second limb and doubled features (streaks once sharpened). Fix:
     band-pass the cross-power (periods 6–200 binned px), fit a robust drift path,
     then re-align against a stack of good frames, searching only ±5 px from the path.
     Reference implementation: the session's `processing/scripts/stack20b.py`.
   - Feather each tile from where it actually has data, not just its frame edge;
     otherwise blank borders blend in as dark seams.

8. **Live histogram + auto-calibrate exposure.** Match the ASICap "~300" target in
   8-bit terms; this capture had headroom (peak 243/255, ~0% clipping) and could
   expose a bit longer. Minimize shutter, keep gain reasonable.

9. **GUI pan / nudge with self-terminating moves.** The operator had to use the HC
   buttons, which sometimes don't stop (runaway). Provide safe, bounded pan in-app.

10. **Standard session output layout + report.** Reproduce the recovery layout per
    run: root named in LOCAL time; top level has the final PNG, report.pdf,
    metadata.json/.toml, aim-points.png, final-annotated.png; `captures/` and
    `processing/` below. Keep real session data in the private data folder, never
    the public repo.

11. **Pure-alt-or-az move planning (analysis).** Plan so each step is a single-axis
    move where possible — roughly halves the chance of a wrong-motor move.

See also: build spec `docs/plan.md`; recovery scripts archived in the session's
`processing/scripts/`.
