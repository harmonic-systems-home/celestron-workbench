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

`ios/ImuLogger/` has two parts:

- `Core/`: the `ImuLoggerCore` Swift package. Wire messages, framing, sequencing, the bounded acquisition buffer, rate measurement, attitude continuity, the NDJSON session log, delivery tracking and the network uplink. Everything here is tested on the Mac, including the uplink against a fake receiver on loopback (interruptions, resend, rejection). The tests decode the same shared examples as the Rust tests.
- `App/` with `ImuLogger.xcodeproj`: the iPhone app. Core Motion acquisition, the session pipeline and the SwiftUI screens.

```sh
cd ios/ImuLogger
swift format lint --strict -r Core/Sources Core/Tests Core/Package.swift App
(cd Core && swift test)
xcodebuild -project ImuLogger.xcodeproj -scheme ImuLogger \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

### Running on your iPhone

Signing reads your team ID from the `APPLE_TEAM_ID` environment variable (exported from your shell profile), so it is never committed. The bundle ID is `com.popperbiz.ImuLogger`; set `CWB_BUNDLE_ID_PREFIX` to change the prefix.

- **Command line:** `xcodebuild` sees the variable directly:

  ```sh
  cd ios/ImuLogger
  xcodebuild -project ImuLogger.xcodeproj -scheme ImuLogger \
    -destination 'generic/platform=iOS' -allowProvisioningUpdates build
  ```

- **Xcode app:** Xcode launched from the Dock doesn't see shell variables. Run this once (and again if the team changes); it writes the git-ignored `ios/ImuLogger/Config/Local.xcconfig`:

  ```sh
  scripts/ios-local-config.sh
  ```

  Then open `ios/ImuLogger/ImuLogger.xcodeproj`, choose your iPhone, and run.

On first use of a receiver, iOS asks for local network access; allow it. The simulator has no motion sensors, so it can only show the interface. Real recordings need the phone.

### Using the logger

- **Send to:** a Mac receiver found by Bonjour, an address you type in (default port 47800), or nowhere. With no receiver, the session is still recorded in full on the phone.
- **Start recording** creates a session ID and a log file `Sessions/<UTC time>_<id>.ndjson` in the app's Documents folder. The screen stays awake while recording.
- **Live** shows the rate each stream actually delivers, measured from sensor timestamps; samples dropped on the phone; buffer high water; rotation since the start; and attitude discontinuities.
- **Markers** are timestamped on the phone clock; add one before and after each fixture movement.
- **Recorded sessions** lists the logs for export (share sheet), and they also appear in the Files app under IMU Logger. Check a log on the Mac with `cwb validate <file>.ndjson`.

Session logs are private data (docs/privacy.md); keep them out of this repo.

## CI

`.github/workflows/ci.yml` runs all of the above on every push and pull request (Rust on Linux, Swift on macOS). `.github/workflows/privacy.yml` runs the privacy check.

## Changing the protocol or the database

- **Protocol:** edit `schemas/protocol/v1.schema.json`, then the Rust types (`rust/crates/protocol/src/message.rs`) and the Swift types (`ios/ImuLogger/Sources/ImuLoggerCore/Messages.swift`). Add or update an example in `schemas/protocol/examples/`. A breaking change means a new protocol version.
- **Database:** add `schemas/sql/NNNN_description.sql` and register it in `MIGRATIONS` in `rust/crates/storage/src/lib.rs`. Never edit a committed migration.
