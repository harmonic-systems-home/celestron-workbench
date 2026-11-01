# ADR 0019: A Moon mosaic app driven by motor positions

**Status:** Accepted

## Context

The operator wants detailed Moon mosaics with the ZWO ASI482MC's narrower sibling, an ASI662MC (1920 × 1080, 2.9 µm pixels): at the 8″ EdgeHD's 2000 mm, 0.30″ per pixel and a 9.6′ × 5.4′ field, against a Moon 29–34′ across. ASIAIR's mosaic plans plate-solve every tile, which fails when the Moon fills the frame; as of 2026-10-31 there is no fix (a ZWO forum request for mosaics from a synced mount without solving has no answer; references.md). SharpCap has a guided Moon mosaic planner that needs no solving, but runs on Windows.

This project already has what a guided mosaic needs: gotos by motor position that end within ±1 unit (0.08″) and can always finish from the same side (O11, O14, ADR 0014), with anti-backlash not acting on them; a tested Rust adapter that stops gotos properly (O11) and survives the hand controller's late replies (O18); the site's coordinates (git-ignored config); frame registration by phase correlation that measured the camera's scale and rotation from the encoders (O17); ZWO's camera library, installed with ASIStudio; and a Mac app pattern for night use (ADR 0018).

The Moon is often up in daylight, so daytime sessions should be possible.

## Decision

### The app

`macos/MoonMosaic/`, a Swift package like the AUX Listener: a tested core and a SwiftUI app, night palette (and a day palette for daylight), big buttons, no typing. It talks to the hand controller directly, through the **existing Rust adapter** linked in as a library: one implementation of the protocol, its stop, re-aim and resync behaviour, and its tests.

- **`cwb-mount-ffi`** (new crate): a small C interface over `mount-celestron` and `mount-core`: open the port, prepare (tracking off, anti-backlash read), read positions, goto, slew-done, stop, close, and events. Built as a static library for Apple silicon and Intel; a script builds it and the app together.
- **Swift side:** a thin wrapper over that interface, tested against the Rust simulator through the same library.

### Encoders are the feedback; the phone isn't needed

The runner moves only with the phone's IMU confirming motion (ADR 0005). This app makes only small gotos near the Moon, and the motors' own positions check every one: overshoot, missed target, a stall past its deadline, motion the wrong way, and motion while idle. `mount-core` gains an **encoder-only profile** that allows gotos only (no timed or keypad moves), arms on two equal position reads instead of IMU stillness, and keeps every encoder check. What it can't see is the tube not following the motor (a slipping clutch); here that costs a bad tile, which the operator redoes. The operator stays at the power switch.

### Where the Moon is

- **Centre by hand:** the operator centres the Moon (arrow keys, rate 5) and presses *Here*. The app records the encoder positions and the time.
- **Track by computation:** from the site and the clock, a low-precision lunar theory (Meeus, *Astronomical Algorithms*, ch. 47), made topocentric (parallax) and refracted, gives the Moon's azimuth and altitude; only the change since *Here* is used, so constant errors cancel. Each tile's target is the encoder position at *Here* plus that change plus the tile's offset, with azimuth offsets divided by cos(altitude). No tracking runs; the app re-aims before every tile.
- **Tested** against published examples (Meeus's worked example for the Moon, and the Sun's) and against long synthetic sessions.

### Camera, calibration and plan

- **Camera:** ZWO's ASICamera2 library, loaded from where ASIStudio installs it (or a path in config; never committed). A fake camera rendering a synthetic Moon drives the tests.
- **Calibration** after *Here*: two small gotos, one per axis; phase correlation of before and after frames gives the camera's rotation and scale against azimuth and altitude, so the camera can sit at any angle.
- **Plan:** a grid in the camera's own frame covering the Moon's disk (its size from the ephemeris), 25% overlap by default, tiles that miss the disk dropped, a serpentine order; about 30 tiles for this camera.
- **Each tile:** goto with a fixed approach side on both axes (so backlash drops out), wait for two equal position reads and a steady image, record a SER video (frames with timestamps; length set in the app), next tile. **Pause**, **Redo tile** and **Stop** are always on screen; a grid shows done, current and remaining tiles.

### Checking the mosaic in the field

- **Preview**, in the app, needing nothing installed: for each tile, a quick lucky-imaging stack (the sharpest frames by a focus measure, aligned by phase correlation, averaged); tiles placed at their known positions (encoders and calibration), refined by phase correlation on the overlaps, and feathered together. It shows the mosaic within seconds of the last tile and flags gaps, overlaps thinner than planned and soft tiles; tapping one queues it for **Redo**.
- The same code (Swift in the app, Python with numpy for the script below) so the field check and home processing agree.

### Processing at home, on the desktop Mac

`scripts/moon-process.sh <session folder>`:

1. **Stack** each tile's SER with Planetary System Stacker in Surface mode (`PlanetarySystemStacker -m Surface …`). The script's own quick stack (the sharpest quarter of the frames, aligned by phase correlation to the one nearest the video's middle, averaged) stands in with `--quick`, without PSS, and for a tile PSS can't align (mostly sky).
2. **Stitch** with Hugin's command-line tools: `pto_gen`, each tile seeded where the session log puts it (the part of the Moon at its centre, in the camera's pixels, from the encoders and the calibration; all tiles one lens, so a tile PSS trimmed sits in a frame-sized canvas with a transparent border); `cpfind --prealigned` for control points between tiles that overlap there; matches more than 30 px (or 8% of the frame) from where the seeds put them dropped, since the Moon's texture repeats enough to pair a tile a whole step off; `cpclean`; `autooptimiser` for positions only, the tile nearest the Moon's centre fixed; a tile it still moves more than half a frame is put back at its seed and named; `nona` and `enblend`.
3. **Write** `<session>/mosaic.tif`, 16 bits per channel, in the camera's orientation and scale, centred on the Moon, for sharpening (and turning north up) in Siril. Work files go in `<session>/processing/`; stacked tiles there are reused on a second run.

`scripts/moon-process-test.sh` runs it on a synthetic session (`MoonMosaicSynth`: the fake camera's Moon with aiming errors up to 8% of the frame, drift, jitter and noise, plus the truth image) and scores the mosaic against the truth: on the first run both routes covered the whole Moon, within 5 px of centre, with every detailed 128-px block matching.

**Tools** (all free; checked 2026-10-31 on the desktop Mac, Apple silicon):

| Step | Tool | Install |
|---|---|---|
| Capture (the app uses its library) | ASIStudio | ZWO's download |
| Stack | Planetary System Stacker 0.9.9 (GPL) | Python 3.10 environment, from its GitHub source: the published package is labelled Intel-only and pins an old numpy, but the source installs natively |
| Stitch | Hugin 2019.2 command-line tools (GPL) | `brew install --cask hugin`; Intel-only and unsigned, so it runs under Rosetta and each tool needs approving once in Privacy & Security |
| Sharpen | Siril | its download |

The field laptop needs only the app (and ASIStudio for the camera library).

### Safety

- **The Sun:** the app computes the Sun's position too and refuses to start, or stops, if the Moon is within 40° of the Sun. Near the quarters the Moon is about 90° away.
- **Limits:** each goto at most the tile step plus the Moon's motion since the last tile (well under `max_goto_deg`, 0.2°); every target within the Moon's disk plus one tile of the computed Moon position, so a wrong calculation can't send the tube far (this replaces ADR 0015's fixed excursion from the arming point, since the Moon itself moves about 15° an hour); the altitude envelope as in config.
- **Stops:** the adapter's (re-aim, then tracking off and fixed rate 0); quitting or losing the link stops.

### Logs and privacy

Each session writes `session.ndjson` in its folder, beside its SER files, in the folder chosen in the app (outside this repo): first the plan (frame size, colour pattern, overlap, the Moon's size, the calibration, each tile's planned centre and pointing), then a line per tile captured (file, frames, the first and last frames' times, the mount's axis angles, and the part of the Moon at the frame's centre midway through the video) or failed (why). Site coordinates come from the app's settings and are not written into it; the times and axis angles together would still place the site roughly, so session folders stay out of anything shared.

Each connection also writes a **mount trace**, `mount-traces/<time>.ndjson` in the same folder: every byte to and from the hand controller (a line per write, per reply, per read that timed out), with the app's requests, the controller's state changes, positions and messages, flushed line by line so a hang or a power cut leaves everything before it. The adapter never asks the hand controller for its time or site, and the port name is redacted; the motor counts and times would still say something about the site with the session log, so traces stay out of the repo too.

### After the first daytime trial

The hand controller twice stopped taking key presses, and once a keyed move ran on until the mount's power was cut: the hand controller itself hung mid-move, so neither its keys nor the app's stops (which go through it) reached the motors. The cause isn't known yet. In response:

- **Fewer reads before arming:** idle position reads every 2 s until the mount is armed (the altitude reference, just before arming, brings back four a second), so the app adds little traffic while the keys are in use.
- **An alarm** when the hand controller stops answering: the link lost, or no idle read for 8 s. A red banner and a repeating sound say to cut the mount's power if it is moving.
- **The trace** above, to see what came just before the next hang; the AUX Listener (ADR 0018) will show whether the hand controller stops sending on the bus.
- Until then, search for the Moon with the app disconnected, and keep the mount's power switch in reach.

### Order of work

1. `mount-core` encoder-only profile, with simulator safety tests (overshoot, stall, idle motion, a goto past the limits refused).
2. `cwb-mount-ffi` and the Swift wrapper, tested against the simulator.
3. Moon and Sun positions, tested against published examples.
4. Camera access with the fake camera; calibration and the planner, tested on a synthetic Moon.
5. The app: *Here*, calibrate, plan, run, redo, Preview, with the night and day palettes (automatic by default: red from civil dusk to dawn at the site).
6. `scripts/moon-process.sh`, tested on a synthetic session.
7. A daytime trial on the Moon, then a night session.

## Consequences

- Moon mosaics without plate solving, from the encoders and the clock.
- A second way to move the mount, without the IMU; it is limited to small gotos near a computed Moon position, and its safety tests run in the same simulator as the runner's.
- A C interface to the Rust adapter, which other Mac apps (the AUX Listener's sessions, a future runner app) can share.
- The camera library is ZWO's, used where it is installed; the app depends on ASIStudio (or ZWO's SDK) being present.
