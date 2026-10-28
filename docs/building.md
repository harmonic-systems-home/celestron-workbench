# Building and testing

Everything here runs without a phone or a mount. Nothing in the repo can move a mount yet.

## Requirements

- macOS with Xcode 16 or later (Swift 6, `swift format`)
- Rust via [rustup](https://rustup.rs). The pinned toolchain in `rust/rust-toolchain.toml` installs itself on first use.
- Optional: `exiftool` (`brew install exiftool`) so the privacy check can inspect images

After cloning:

```sh
git config core.hooksPath .githooks   # pre-commit privacy check
```

## Rust (Mac side)

```sh
cd rust
cargo fmt --all --check
cargo clippy --all-targets -- -D warnings
cargo test
```

`cargo test` includes:

- **Schema conformance** (`crates/protocol/tests/examples.rs`): every file in `schemas/protocol/examples/valid/` passes the JSON Schema and round-trips through the Rust types unchanged; every file in `invalid/` fails.
- **Migration tests** (`crates/storage/tests/migrations.rs`): every migration applies to an empty database; constraints, foreign keys and append-only triggers work; every file in `schemas/sql/` is registered.
- **Framing** and **mount state machine** unit tests.

### The `cwb` command

```sh
cargo run -p cwb-cli -- versions
cargo run -p cwb-cli -- validate path/to/message.json path/to/session.ndjson
cargo run -p cwb-cli -- migrate --db /path/outside/repo/workbench.sqlite   # or set CWB_DB
```

Keep databases outside the repo (see [privacy](privacy.md)).

## Swift (phone side)

```sh
cd ios/ImuLogger
swift format lint --strict -r Sources Tests Package.swift
swift test
```

`ImuLoggerCore` holds the platform-independent code (wire messages, framing, CRC) and runs its tests on the Mac. The tests decode the same shared examples as the Rust tests, so both sides agree on the wire format. The iPhone app target (Core Motion, UI) arrives with plan Prompt 2.

## CI

`.github/workflows/ci.yml` runs all of the above on every push and pull request (Rust on Linux, Swift on macOS). `.github/workflows/privacy.yml` runs the privacy check.

## Changing the protocol or the database

- **Protocol:** edit `schemas/protocol/v1.schema.json`, then the Rust types (`rust/crates/protocol/src/message.rs`) and the Swift types (`ios/ImuLogger/Sources/ImuLoggerCore/Messages.swift`). Add or update an example in `schemas/protocol/examples/`. A breaking change means a new protocol version.
- **Database:** add `schemas/sql/NNNN_description.sql` and register it in `MIGRATIONS` in `rust/crates/storage/src/lib.rs`. Never edit a committed migration.
