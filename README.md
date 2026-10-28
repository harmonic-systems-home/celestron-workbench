# Celestron Workbench

Diagnostics for Celestron computerized telescope mounts, using an iPhone's motion sensors as an independent observer of what the mount actually does.

Developed on a NexStar Evolution 8 EdgeHD with StarSense, an iPhone 17 Pro Max and a MacBook. The mount-specific code sits behind an adapter, so the rest of the system doesn't depend on one particular mount.

> **Status:** M0 foundation. Protocol schema, database schema, decision records and CI are in place; no hardware code yet. See [docs/plan.md](docs/plan.md).

## What it does

1. **Bench characterization** (Phase 1). An iOS logger (Swift, Core Motion) streams timestamped motion samples to a Mac recorder (Rust, SQLite). Reproducible reports measure noise, drift, timing and known rotations of the phone and its cradle before it goes near a telescope.
2. **Indoor mount diagnostics** (Phase 2). Short, low-speed, single-axis commands run behind a safety state machine with interlocks. The phone measures onset, rate, settling, reversal and backlash.
3. **Optical truth** (Phase 3, optional). Plate solves provide an absolute sky reference. ASIAIR data can be imported, but ASIAIR is never a safety dependency.

## Repository layout

| Path | Contents |
|---|---|
| [docs/plan.md](docs/plan.md) | The build specification |
| [docs/adr/](docs/adr/) | Architecture decisions: time, frames, storage, transport, mount safety |
| [docs/building.md](docs/building.md) | Build and test instructions |
| [docs/assumptions.md](docs/assumptions.md) | What still has to be verified on real hardware |
| [schemas/](schemas/) | JSON Schema for the phone–Mac protocol, shared examples, SQL migrations |
| [rust/](rust/) | Mac side: `protocol`, `storage`, `mount-core` (state machine only), `cli` (`cwb`) |
| [ios/ImuLogger/](ios/ImuLogger/) | Phone side: `ImuLoggerCore` Swift package; the app target arrives in M1 |

## Safety

This software can move a telescope. Mount motion stays disabled until the simulator safety suite passes and the operator has proven an independent stop, such as the power switch within reach. Goto and unattended operation are out of scope. Read the safety sections of the plan before connecting hardware.

## Privacy

Real session data (observing location, device identifiers, network details, photos, FITS files) lives outside this repo. Only synthetic or sanitized fixtures are committed. See [docs/privacy.md](docs/privacy.md).

After cloning, enable the pre-commit privacy check:

```sh
git config core.hooksPath .githooks
```

## Disclaimer

Not affiliated with or endorsed by Celestron. Celestron, NexStar, StarSense and EdgeHD are trademarks of Celestron, LLC. ASIAIR is a trademark of ZWO. Use at your own risk.

## License

[MIT](LICENSE)
