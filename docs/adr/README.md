# Architecture decision records

Each ADR records one decision, why it was made, and what it costs. To change a decision, add a new ADR that supersedes the old one; don't rewrite history.

| ADR | Decision | Status |
|---|---|---|
| [0001](0001-timestamp-domains.md) | Timestamps stay in their own clock domains | Accepted |
| [0002](0002-coordinate-frames.md) | Coordinate frames, units and quaternion convention | Accepted |
| [0003](0003-storage.md) | SQLite via rusqlite, single writer, append-only raw data | Accepted |
| [0004](0004-network-transport.md) | Framed JSON over TCP on local Wi-Fi | Accepted |
| [0005](0005-mount-safety.md) | Mount safety state machine and interlocks | Accepted |
| [0006](0006-phone-owns-session.md) | The phone starts and owns a recording session | Accepted |
| [0007](0007-step-and-settle-measurement.md) | Mount characterization uses step-and-settle and hold tests | Accepted |
| [0008](0008-bench-analysis.md) | Bench analysis is deterministic, configured in TOML, and starts with stationary metrics | Accepted |
| [0009](0009-characterize-on-the-scope.md) | The phone is characterized on the scope, not on a bench fixture | Accepted |
| [0010](0010-celestron-discovery.md) | Read-only Celestron discovery through the hand controller's serial port | Accepted |
