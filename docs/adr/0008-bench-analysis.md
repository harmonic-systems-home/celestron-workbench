# ADR 0008: Bench analysis is deterministic, configured in TOML, and starts with stationary metrics

**Status:** Accepted. The fixture-based metrics it defers are dropped by [ADR 0009](0009-characterize-on-the-scope.md).

## Context

Plan Prompt 5 asks for a deterministic analysis CLI with versioned YAML configurations, covering stationary noise, timing, drift, indexed rotations, attachment repeatability, power spectral density and bootstrap confidence intervals. ADR 0007 makes step-and-settle the main mount method, which needs two numbers first: how small a step the phone can resolve for a given settle-window length, and how fast it drifts while still. There is no rotation fixture yet, so indexed-rotation and attachment metrics have no data to run on.

## Decision

- **First slice: stationary analysis** (`cwb analyze`, crate `cwb-analysis`, method `stationary_v1`):
  - **Timing:** per-stream rate and interval statistics, long gaps, missing sequence numbers, drops on the phone, and the session's clock models.
  - **Still windows:** the fused rotation rate's magnitude, smoothed, below a threshold for a minimum time; trimmed at both ends; split at timestamp gaps. Windows inside the warm-up are reported but excluded from steady state.
  - **Noise and drift per steady window:** mean, sd, RMS, MAD and 5th–95th percentiles, and a least-squares drift per minute, for tilt (from fused gravity and from the raw accelerometer), heading (twist about the reference frame's vertical, unwrapped), and the raw gyro.
  - **Resolution versus window length:** the Allan deviation of each angle channel at a range of averaging times, from the longest steady window. For an angle, this is the noise in comparing two adjacent still windows of that length, divided by √2, so the smallest resolvable step is about k × √2 × that value. Core Motion's fused tilt and heading are filtered, so their values at very short τ understate the noise; the best-resolution search starts at `min_window_s`.
  - **Moves:** the rotation between consecutive still windows' mean attitudes (angle, axis in the first window's device frame), the heading change, and the change in gravity direction.
  - **Acceptance:** delivered rate, missing samples, clock uncertainty and steady-state time against configured limits. A check without data (for example, no clock exchanges) is "not measured", which makes the decision provisional rather than failed.
- **Configs are TOML, not YAML.** The maintained Rust YAML libraries have churned (`serde_yaml` is archived), while TOML has one stable library and is already this repo's config format (`site.toml`). Configs live in `analysis/`, carry a format `version` and a `name`, and reject unknown keys. The default is compiled in from `analysis/stationary.toml`.
- **Reports are deterministic.** Output depends only on the stored session and the config: no run timestamps, fixed number formatting, no randomness. Every report names the session export's SHA-256, the config's SHA-256, and the software and schema versions. Files: `report.md` and `report.html` (same content), `metrics.json`, `windows.csv`, `resolution.csv`, and SVG plots. Reports go to the git-ignored `reports/` folder by default.
- **Recorded and synthetic sessions take the same path.** Golden tests store synthetic sessions with known truth through `Store` and analyse them with the same loader: zero motion, known gyro bias and heading drift, known rotations, missing data, heading across ±180°, quaternion sign flips, and byte-identical reports.

## Consequences

- Not yet implemented: power spectral density, bootstrap confidence intervals (they need repeated trials), indexed rotations against a fixture, attachment remove-and-replace, and environment comparisons. Each report lists these as not analysed.
- Results are only as good as the still-window detector, which is also the planned on-phone settle detector (ADR 0007); its thresholds are config values so both can be tuned from the same evidence.
