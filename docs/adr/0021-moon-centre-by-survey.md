# ADR 0021: Finding the Moon's centre by survey, and earthshine tiles

**Status:** Superseded by [ADR 0022](0022-attended-moon-acquisition.md) as the
acquisition path (camera brightness centroid replaces the survey + circle fit).
The circle fit may still inform mosaic centring later. Originally: Proposed,
amends ADR 0019, "Where the Moon is" (centre by hand).

## Context

ADR 0019 has the operator centre the Moon by hand and press *Here*; every tile is aimed from that point. The camera sees 9.6′ × 5.4′ of a Moon 29–34′ across, so at any phase only a patch shows and the centre is a guess. On a crescent it's worse: the centre lies in the dark part, a full Moon radius in from the bright limb.

The plan also covers the whole disk at one exposure, so on a thin crescent most of its tiles are dark. Yet a crescent under about 30% lit shows earthshine: sunlight reflected by the Earth lights the dark side, roughly 1,000 to 10,000 times fainter than the sunlit part, showing maria, highlands and bright craters. Those tiles are worth taking, with their own exposure.

## Decision

### Here: anywhere on the lit Moon

The operator puts any part of the sunlit Moon in view and presses *Here*. Calibration (two small moves, ADR 0019) runs there, on lunar texture, as before.

### Find centre: a survey, and a circle fit

- **The survey.** Frames on a grid around *Here*, 1.4 frames apart, reaching 1.5 Moon radii from it. *Here* is on the Moon, so the survey always reaches past the nearest limb. One goto per frame, without touch-ups: where the camera really pointed comes from the mount's own position at the frame's time, and the Moon's computed motion. It uses its own exposure and gain (default 100 ms, gain 300) so earthshine shows above the sky; the sunlit part saturates.
- **Cells.** Each frame is cut into 80-pixel cells, and each cell is placed on the sky through the calibration. The sky level comes from the darkest fifth of the cells. A cell is **Moon** if it's clearly above the sky, and **lit** if it's more than halfway from the sky to the brightest cells.
- **The fit.** The app fits a circle of the Moon's radius, from the ephemeris, searching within 1.1 radii of *Here*:
  - Moon cells inside the circle count for it; Moon cells outside count strongly against it, lit ones most.
  - Sky cells outside count for it. Sky cells inside count only weakly against it, because without earthshine the dark side reads as sky.
  - With earthshine, the whole disk is above the sky at any phase. Without it, the crescent's outer edge is itself an arc of the Moon's radius, so it pins the circle.
  - Cells within 15″ of the edge don't count.
- **It refuses rather than guesses.** If fewer than 85% of the counted cells agree with the circle, the app reports that it couldn't find the edge, and *Here* stays where it was.
- **Here moves to the centre.** The mount's altitude reference, set at *Here*, is set again from the found centre. Every target after that works as in ADR 0019.

### Lit and dark tiles

- **The plan marks each tile lit** if a lit survey cell falls in its frame, within a cell's margin.
- **Start captures lit tiles only.** The preview doesn't count dark tiles that haven't been taken as missing.
- **Earthshine** captures the dark tiles at whatever exposure and gain are set when it's pressed. The operator turns them up first, keeping frames short (about 100–300 ms) because the Moon drifts about 15″ a second untracked.
- The dark tiles make their own mosaic, combined with the lit one at home.

### Safety

The survey's moves are small gotos near the computed Moon, under the same encoder-only profile and checks as tiles (ADR 0019). Each leg stays under about 0.5°, inside the app's 1° leg limit, and no stop is further than 1.5 Moon radii from *Here*. The survey arms the mount for its own moves and disarms after, like every other step.

## Consequences

- No centring by eye at any phase: *Here* only has to be on the lit Moon.
- On a crescent, fewer tiles at the lit exposure, about 15 instead of about 40 at 20% lit, and an optional earthshine pass for the rest.
- The survey takes about 25–30 frames, a few minutes on the mount. That's slower than centring by hand, and the Moon moves meanwhile, which the targets already account for.
- The fit depends on the survey exposure. If the sky is as bright as earthshine (twilight, a low Moon), the fit falls back on the lit edge. That works at any phase but is less exact on a very thin crescent, and the preview's gap check stays the backstop.
- Tested on synthetic cells at full, gibbous, half and crescent phases, with and without earthshine, and on the simulated mount with a 20% crescent and *Here* 650″ from the centre.
