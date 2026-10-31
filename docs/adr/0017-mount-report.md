# ADR 0017: The Phase 2 mount report

**Status:** Accepted

## Context

Phase 2's exit evidence is "a Phase 2 report for both axes" (plan, M5), and its acceptance criteria ask that a replay gives the same metrics, with uncertainty, pose and attachment stated. The results so far (O9–O16) were worked out with throwaway scripts: encoder against phone per move, take-up and over-correction on reversals, speeds. One of them picked the wrong runner's clock for a while (O16), which is the case for doing this in the repo, tested.

Each runner session writes a run log (`reports/mount/<time>/run.ndjson`) with the config (anti-backlash included since O14), every request and its record (commanded and phone-observed travel, lifecycle stages, goto positions), the mount's position reads, every serial exchange with its send and reply times, faults and operator notes. Older logs differ: the first records have a flat request, and logs from before the setting existed have no anti-backlash (the runner then required 0).

## Decision

- **`cwb mount report <run logs or folders>...`** (method `mount_v1`, in `cwb-analysis`), from run logs alone. Phone traces through the database are a later addition (below).
- **Order: answer first.** The report opens with the method and runs, then what's established about the mount, then the recommended anti-backlash, then how the mount performs at it; everything else follows as supporting evidence.
  - **What we know:** identity and motor-controller settings from the latest hardware discovery report (`--discovery`, default the latest in `reports/discovery`); the position scale (2²⁴ units per revolution) with the phone's check on one-way moves and O12's against gravity; units per millimetre at the leading edge (`[geometry]`, an estimate); typical slack; a table of which commands anti-backlash acts on (yes, partly or no from their take-up); and the protocol findings, quoted from `[findings]` in the config with their sources.
  - **Recommended anti-backlash:** per axis, for the arrow keys' fine rates (keypad 1–5): among the settings where each such move type was tried, the one with the smallest mean |reversal error|. The same rule for timed moves is shown beside it, and the last run's setting, flagged if it differs.
  - **Performance:** a chart, then a table, of each fine rate's reversal error at the recommended setting against its uncorrected slack, and what that setting doesn't compensate: gotos and keypad rates 6–9.
- **Per move:** axis, kind (timed at a rate, keypad rate *n*, goto slow or fast), size, direction, anti-backlash for that axis, encoder travel, phone-observed travel, and history: a **reversal** if the axis last moved the other way in the same run, a **repeat** if the same way, **unknown** for the first move on an axis in a run or after a fault. Encoder travel is the last position read before the command left to the first read 2.5 s after the stop (gotos use their own start and last positions). Faulted moves are listed and left out of the statistics.
- **Per group** (axis, kind, size and anti-backlash): means and standard errors of encoder and phone travel on repeats and reversals, and from them:
  - **motor take-up** = encoder on reversals − encoder on repeats;
  - **over-correction** = phone on reversals − phone on repeats (0 is ideal; negative is slack left);
  - **slack** = take-up − over-correction, the lost motion the reversal had to cross.

  Take-up's and over-correction's errors combine the two means' standard errors; slack's comes from the spread of each move's phone − encoder, since encoder and phone on the same move aren't independent. A move whose phone − encoder difference lies more than 4 robust deviations and 30″ from its group's is flagged as disturbed (footsteps, a vibration: O16) and left out, and listed.
- **Keypad speeds:** encoder travel on repeats over the time from sending to stopping, per axis and rate, against Celestron's list.
- **Link health per run:** command exchanges (latency median and longest, failures, those over 400 ms) and the gaps between position reads while no command is in flight (median, 95th percentile, longest, those over 600 ms: O7's stalls). The run logs time commands but not position reads, so the read gaps are where the stalls show. This is the baseline for ADR 0016.
- **Lifecycle:** every request has a record ending in completed, cancelled, rejected, timed out or unknown; any that doesn't is listed.
- **Graphs (SVG):** over-correction against anti-backlash per axis, one series per kind tried at two or more settings, with error bars and the zero line; motor take-up against anti-backlash; every move's phone − encoder difference by setting, reversals and repeats apart, so outliers and spread show; keypad speeds against Celestron's list; distributions of command latency and read gaps.
- **Deterministic and configured as ADR 0008:** `analysis/mount.toml` (settle time, outlier limits, stall threshold); output depends only on the logs and the config, and the report names each log's SHA-256 and the config's. Files: `report.md`, `report.html`, `metrics.json`, `moves.csv`, `groups.csv`, SVGs. Tests use synthetic run logs with known backlash, take-up and speeds.

## Consequences

- O9–O16's numbers become reproducible from the logs with one command, and new trials join the same tables.
- The phone's travel is the runner's own measure (`observed_deg`), as the trials used. Per-move traces of encoder and phone angle through a reversal, tube angle per move, and the daytime camera's shifts (ADR 0015) need the database and come next.
- Pose, balance and attachment aren't in the logs; the report states them as not recorded rather than guessing.
