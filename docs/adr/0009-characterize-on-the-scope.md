# ADR 0009: The phone is characterized on the scope, not on a bench fixture

**Status:** Accepted. Supersedes the plan's rotation-fixture requirement (plan § Bench fixtures, Phase 1 acceptance) and the fixture-based items deferred in ADR 0008.

## Context

The plan's Phase 1 calibrates the phone against a turntable or indexed fixture before it goes on the mount. To check a phone that resolves steps of roughly 0.01–0.03° (ADR 0008, first table recordings), a fixture would need reference angles near 0.005°, which means buying precision metrology to calibrate a consumer sensor. Hand positioning on a table is far coarser than that, and Apple's sensor specifications already cover what a rough table test would show. The mount's two motors are the only motion that can be commanded in discrete, repeatable steps, and they are what this project characterizes.

## Decision

- **No rotation fixture.** Indexed-rotation, fixture scale and cross-axis tests on the bench are dropped.
- **Table work is limited to:**
  - The pose checks already done: axis signs and gravity on several faces (docs/assumptions.md, P3 and P4).
  - A 30-minute still recording: resolution versus window length, drift, the app's 30-minute run (P7), and the baseline that mount hold tests are compared against (ADR 0007).
- **Phone and mount are characterized together on the scope**, with Move and Measure (ADR 0007):
  - Long moves in one direction give the combined scale. Backlash affects reversals, not the total of a long one-way move, so the mount's commanded angle is the reference (assumption M6).
  - Reversals give the deadband.
  - Holds give droop against the table baseline.
  - Remove-and-replace of the phone in its scope holder gives attachment repeatability.
- **Results describe the phone-plus-mount system.** The phone may resolve finer than the mount can show; that is acceptable. Absolute angles, if ever needed, come from the sky (plate solving, plan Prompt 9).

## Consequences

- The safety gate is unchanged: no motion until the simulator suite (plan Prompt 6) and the operator checklist pass. Characterization therefore waits for Prompts 6–8.
- The step-sequence analysis (scale, endpoint error, repeatability and lost motion per step, against commanded angles) is built with the test runner (plan Prompt 8), not against a fixture.
- Phone error and mount error cannot be separated on the scope without an outside reference. The table still recording bounds the phone's own noise and drift; anything larger is attributed to the mount and holder until the optical check says otherwise.
