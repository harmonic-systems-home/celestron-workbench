# ADR 0015: A daytime optical check against a terrestrial target

**Status:** Accepted

## Context

Everything measured so far on the tube side comes from the phone, taped to the tube: the IMU sees the tube, the tape and the floor together, with ±15–35″ of scatter on small moves (O15, O16). The plan's independent reference is plate solving (Prompt 9), which needs clear night skies, and none are likely for two to three weeks.

A camera at prime focus watching a fixed target measures where the optics point, to well under the phone's scatter, and needs only daylight. The operator has a ZWO ASI482MC (1920 × 1080, 5.8 µm pixels, colour, USB 3) and an 8″ NexStar Evolution (2032 mm, f/10, no reducer): 0.59″ per pixel and a 19′ × 11′ field. Backlash is about 130 pixels in altitude (75″) and 270–300 in azimuth (160–180″); a 0.1° move is about 610 pixels. A usable target is visible from the current indoor setup: a building with sharp corners about 110 m away, through a window. At that distance the field covers about 63 × 36 cm, and the camera's offset of a few tenths of a metre from the axes changes measured angles by about 0.3%. Shimmer over a short path is smaller than over kilometres but is still the main noise.

## Decision

### Scope

- **An early, terrestrial slice of Prompt 9:** relative image shifts between still windows only. No plate solving and no absolute orientation; those wait for stars.
- **What it answers:** backlash and lost motion as the optics see them, against the motor encoders and the phone, for the moves of O9–O16; whether the tape or the floor moves the phone relative to the optics; the phone's and the encoders' scale (assumption M6).

### Capture

- **ASIStudio (ASICap) on the Mac** records SER video, which timestamps every frame from the Mac's UTC clock. Short exposures at low gain to freeze shimmer; region of interest optional. The camera stays under its own software for now; driving it through ZWO's SDK is a later option if the measurement proves worth it.
- **The runner logs wall-clock time:** a `clock` event pairing its monotonic time with UTC at start and every 10 s, so frames can be matched to moves. Matching needs about a second: the measurement uses still windows, not motion.
- **Import:** `cwb` records each SER file as a session artifact (path relative to the data folder, SHA-256, camera, gain, exposure, frame count, first and last frame time). Image files are never copied into the repo.

### Measurement

- **Step and settle (ADR 0007):** for each still window between moves, frames are converted to luminance and stacked; each window is registered against a reference window by phase correlation with sub-pixel refinement. The scatter of single-frame shifts within a window is its uncertainty (mostly shimmer).
- **Calibration from the session itself:** the image scale and the camera's roll come from long one-way moves on each axis, measured by the encoders (backlash doesn't affect one-way totals, assumption M6). The nominal 0.59″ per pixel is a check, not an input.
- **Per move:** optical shift along each axis, against the encoder's travel and the phone's. Lost motion on a reversal is the encoder's travel minus the optical one; reported with uncertainty, rate, anti-backlash, pose and approach history, as Phase 2 requires. It goes into the Phase 2 mount report.

### Safety

- **Low altitude:** pointing at a terrestrial target needs altitudes below `min_altitude_deg` (5°). A trial config, `config/trials/daytime.toml`, lowers it for these sessions only, with a comment saying why; nothing else is relaxed.
- **The sun:** in daytime the mount isn't aligned, so software can't know where the sun is, and a small travel limit wouldn't help anyway: the sun moves, and could set into a fixed field of view. The protection is the site and the procedure. From the indoor setup the sun can't be seen near the horizon at all (buildings block it below about 10° altitude), so the target can't meet it. For any other setup, the operator checks before the session that the sun's path, from the site and time, stays well clear of the target's direction for the session's length, and keeps a cap for the front of the tube at hand.
- **Travel:** the runner refuses any request that would take either axis more than `max_excursion_deg` (new, 1° in the trial config) from where it was armed. This guards against mistakes in our own requests, such as a typo, a script repeating a move or a wrong sign walking the tube away, which the per-request caps (0.2° per goto, 2° per move) don't bound. The trials need about 0.3°: everything has to stay inside the 19′ × 11′ field.
- **Disturbances:** phone on Do Not Disturb, nobody walking near the scope during a run (O16).

### Privacy

The frames show a neighbour's house: they are real session data. They live only in the private data repo or the local data folder, never in this repo. Tests use synthetic frames: an edge pattern rendered at known sub-pixel shifts, with noise, under `fixtures/`. Site coordinates and the target's location are never written to committed files.

### Order of work

1. **Runner:** `clock` events, `max_excursion_deg` with simulator tests, and the daytime trial config.
2. **Analysis:** SER reader, luminance stacking and phase correlation, tested on synthetic frames with known shifts; artifact import.
3. **Procedure:** a short capture checklist in `docs/building.md` (camera settings, focus, target, timing).
4. **First daytime run** (indoor, through the window): scale and roll calibration with one-way moves, then keypad-rate reversals at rates 5 and 3 on each axis at the chosen anti-backlash (40, 40, 20, 20), with the phone recording alongside.

## Consequences

- Backlash gets a reference independent of the phone, the tape and the floor, weeks before plate solving.
- The camera sees the floor too: a run indoors measures how much the carpet matters, and a later run on concrete (MacBook, outdoors) can be compared with it.
- New dependencies: an FFT crate for phase correlation and a small SER reader.
- `max_excursion_deg` is a new interlock that later sessions can use too.
- Results are relative only; absolute orientation, tracking and goto residuals against the sky still need Prompt 9 proper.
