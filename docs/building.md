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
- **Repository tests** (`crates/storage/tests/ingest.rs`): sessions created and resumed, sequence gaps holding the acknowledgement until filled, resent and conflicting duplicates, refused batches, values stored bit-exactly with `NULL` for unavailable fields, `bye` and incomplete sessions, and an export → import round trip that reproduces the session byte for byte.
- **Network tests** (`crates/receiver/tests/network.rs`): a synthetic phone streams to a real receiver on loopback through dropped connections, corrupted frames, malformed batches, a receiver restart mid-session, a second phone claiming the session, protocol errors, and a one-slot writer queue. Each test checks the stored session is complete.
- **Framing** and **mount state machine** unit tests.

### The `cwb` command

Build it once with `cargo build` (the binary is `rust/target/debug/cwb`), or use `cargo run -p cwb-cli --` in place of `cwb` below. Commands that use the database take `--db` or read `CWB_DB`. Keep databases outside the repo (see [privacy](privacy.md)).

```sh
export CWB_DB=/path/outside/repo/workbench.sqlite

cwb versions
cwb validate path/to/message.json path/to/session.ndjson   # check files against the protocol schema
cwb migrate                                                # create or upgrade the database
```

### Receiving from the phone

```sh
cwb receive
```

This listens on port 47800 and advertises itself with Bonjour as "Celestron Workbench", so it appears under **Send to** on the phone. The first time, macOS may ask whether `cwb` may accept incoming connections; allow it. Options: `--port`, `--name`, `--no-advertise` (then type the Mac's address on the phone), `--bind`. Ctrl-C stops it; sessions that were still recording are marked `incomplete`, and resume if the phone reconnects to a later run.

The phone owns the session (ADR 0006): starting a recording on the phone creates it on the Mac. The receiver validates every message against the schema, stores samples through a single database writer, and acknowledges the highest contiguous seq only after it is committed. Gaps, resends, conflicting duplicates, refused messages, reconnects and clock-domain changes are recorded as `session_events`. Raw samples are never modified or interpolated.

### Working with sessions

```sh
cwb session list
cwb session validate 20009d52          # ID or unique prefix; exits non-zero if anything is missing
cwb session validate 20009d52 --json
cwb session export 20009d52 -o /path/outside/repo/session.ndjson
cwb session import /path/to/phone-log.ndjson
cwb session stop 20009d52              # phone vanished without bye: mark incomplete
cwb session clock 20009d52 [--save]    # fit phone-to-Mac clock models; --save stores them
```

- **validate** reports per-stream sample counts, delivered rates and interval ranges, missing seq ranges, timestamps that did not increase, samples dropped on the phone, whether `bye` arrived and matches, counts of every event kind, and a fresh clock fit.
- **clock** fits one model per device and receiver run from the session's clock exchanges: offset, drift (once there are at least 30 s and 3 good exchanges), and an uncertainty that later timing claims must exceed. `--save` adds the models to `clock_models`; earlier ones are kept.
- **export** writes protocol NDJSON (`hello`, batches, markers, phone events, clock results, `bye`) and prints its SHA-256. The output passes `cwb validate`, imports back to an identical session, and replays. Mac-side ingest events are reported by `validate`, not exported.
- **import** creates a session from the phone's log, or completes one received live: samples already stored are skipped, so it fills in whatever the network missed. Importing the same file twice changes nothing.

### Without a phone

`cwb replay` acts as the phone, with the same handshake, acknowledgements, reconnects and resends:

```sh
cwb receive --db /tmp/scratch.sqlite &
cwb replay path/to/phone-log.ndjson --to 127.0.0.1:47800          # real time
cwb replay path/to/phone-log.ndjson --speed 0                      # as fast as possible
cwb replay --synthetic 60 --rate 100 --speed 0                     # generated session
cwb replay --synthetic 60 --clock-interval 1                       # with clock exchanges
```

A recorded log's clock results replay as recorded; only synthetic sessions run new exchanges, since a recording's phone clock can't be reproduced.

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
- **Recorded sessions** lists the logs for export (share sheet), and they also appear in the Files app under IMU Logger. Check a log on the Mac with `cwb validate <file>.ndjson`, or load it with `cwb session import`.

Session logs are private data (docs/privacy.md); keep them out of this repo.

## CI

`.github/workflows/ci.yml` runs all of the above on every push and pull request (Rust on Linux, Swift on macOS). `.github/workflows/privacy.yml` runs the privacy check.

## Changing the protocol or the database

- **Protocol:** edit `schemas/protocol/v1.schema.json`, then the Rust types (`rust/crates/protocol/src/message.rs`) and the Swift types (`ios/ImuLogger/Core/Sources/ImuLoggerCore/Messages.swift`). Add or update an example in `schemas/protocol/examples/`. A breaking change means a new protocol version.
- **Database:** add `schemas/sql/NNNN_description.sql` and register it in `MIGRATIONS` in `rust/crates/storage/src/lib.rs`. Never edit a committed migration.
