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
- **Clock fit tests** (`crates/storage/tests/clockfit.rs`): offset and drift recovered through Wi-Fi-like delays, and a constant one-way delay staying inside the reported uncertainty. The network tests also check a live exchange over loopback.
- **Analysis golden tests** (`crates/analysis/tests/golden.rs`): synthetic sessions with known answers (zero motion, bias and drift, known rotations, missing data, heading wrap, quaternion sign) and byte-identical reports.
- **Mount safety suite** (`crates/mount-sim/tests/safety.rs`): every injected fault stops the simulated mount or latches with a cut-power alert, plus a randomized search over 1,000 fault combinations (ADR 0005). Run it alone with `cargo test -p cwb-mount-sim`.
- **Celestron discovery** (`crates/celestron-discovery/tests/`): every sendable command is a documented read-only query (no motion, setters, location or time), replies decode as the protocol document's examples, and discovery against the simulated hand controller passes when healthy and fails or warns on a missing motor, silence, tracking on, another model or a moving mount (ADR 0010).
- **Hand controller time and location** (`crates/celestron-setup/tests/`): set time and set location bytes match the documented layout, local time and daylight saving come from the time zone, coordinates round to whole arcseconds, read-back confirms or reports a drifting clock, a forgotten setting or silence, anti-backlash bytes follow libnexstar and every set is read back, only time, location and anti-backlash commands can be sent, and coordinates never appear in `Debug` or error text (ADR 0011).
- **Session sites** (`crates/storage/tests/ingest.rs`, shared examples): a site is stored once, an inconsistent one is refused, it survives export and import, the session list shows the latest environment, and `Debug` hides coordinates (ADR 0012).
- **Mount motion** (`crates/mount-celestron/tests/`, `crates/mount-core/tests/imu.rs`, `crates/mount-runner/tests/`): every transaction the adapter can produce is a documented slew or stop; a move is acknowledged, runs and stops on the simulated hand controller; a dropped link is reported and stops still go out; dropping the adapter stops both axes; preparation turns tracking off; the phone-to-mount axis conversion holds at any roll; the runner measures the raw gyroscope's offset at arming and catches a slow turn iOS's fused rate has absorbed, and it gates moves behind the checklist, asks before each first move, stops on Enter, faults a reversed axis, quits cleanly, logs the session and takes live phone samples through the clock model (ADR 0013).
- **Framing**, **mount state machine** and **safety configuration** unit tests.

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

### Analysing a session

```sh
cwb analyze 20009d52                               # report in reports/20009d52/ (git-ignored)
cwb analyze 20009d52 --config analysis/my.toml -o /path/outside/repo/report
```

It prints the decision and the smallest resolvable step for 1, 2 and 5 s settle windows, and writes `report.html` (and the same as `report.md`), `metrics.json`, CSV tables and SVG plots. The config is [analysis/stationary.toml](../analysis/stationary.toml) unless you pass one; copy it and change `name` when you change values, since every report records the config's name and SHA-256. For the bench protocol's 30-minute stationary trials, set `warm_up_s = 600`. See [ADR 0008](adr/0008-bench-analysis.md) for what each metric means.

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

### Celestron discovery (read-only)

Connect the hand controller's USB port to the Mac, power the mount, and let the hand controller finish starting up. Then:

```sh
cwb celestron ports                 # find the hand controller's /dev/cu.* device
cwb celestron queries               # every byte discovery will send, with references; sends nothing
cwb celestron discover --port /dev/cu.usbserial-XXXX \
    --mount "NexStar Evolution" --hand-controller "StarSense" \
    --hand-controller-firmware "as shown on its display" --cable "USB mini-B"
```

`discover` sends only documented read-only queries (ADR 0010) and writes `report.md`, `report.json` and `trace.ndjson` to a timestamped folder under `reports/discovery/` (git-ignored). It exits non-zero if any check fails. `--simulate` runs against the built-in simulated hand controller instead of hardware, to see the report without a mount. Reports redact USB serial numbers from device paths; review a report before sharing it anyway.

### Hand controller time and location

The location comes from the newest precise phone fix in the database (`--db` or `CWB_DB`; each session records one, ADR 0012). Without one, copy `config/site.example.toml` to `config/site.local.toml` (git-ignored) and fill in your site. Leave the hand controller at its top-level screen, then:

```sh
cwb celestron setup --port /dev/cu.usbserial-XXXX     # time from this Mac; location from the newest phone fix, else the site file
cwb celestron setup --port /dev/cu.usbserial-XXXX --time-only
cwb celestron setup --port /dev/cu.usbserial-XXXX --location-from site-file
```

It checks the hand controller answers, shows what it will send (the site's name and hemispheres, never its coordinates), asks for confirmation, then sets each value and reads it back (ADR 0011).

### Anti-backlash

```sh
cwb celestron backlash --port /dev/cu.usbserial-XXXX                  # read all four
cwb celestron backlash --port /dev/cu.usbserial-XXXX --set-all 0      # set, then read back
cwb celestron backlash --port /dev/cu.usbserial-XXXX --set azm+=20 --set azm-=20
```

Values are 0–99 per axis and direction, set on the motor controllers and read back. `cwb mount run` refuses to start unless all four are 0, so compensation can't hide the backlash being measured. It exits non-zero unless every value is confirmed. `--site FILE` or `CWB_SITE` points at another site file; `--simulate` runs without hardware.

### Moving the mount

`cwb mount run` is the only command that moves the mount (ADR 0013). Rehearse first; it needs no hardware:

```sh
cwb mount run --simulate
```

On the mount: review `config/mount.toml` (axis signs, tube axis, safety limits), strap the phone to the tube with its top toward the sky end, power the mount, connect the hand controller's USB, then:

```sh
cwb mount run --port /dev/cu.usbserial-XXXX --db ~/path/outside/repo/workbench.sqlite
```

It claims the phone's port, checks the hand controller (turning tracking off if needed, and requiring anti-backlash 0), starts receiving from the phone (start a recording on the phone and choose this Mac), and shows the mount-session checklist. Type `yes` once every item holds. Then `status` until the IMU shows fresh with a clock model, keep the mount still for 3 s, and `arm`: it measures the raw gyroscope's offset (the app's Raw gyroscope setting must be on) and from then on the safety checks use the raw gyroscope. Then try a move such as `az+ 0.1 1` (0.1 °/s for 1 s). The first move each way asks for `yes`. **An empty line (Enter) is always Stop.** `help` lists the commands. The run log goes to `reports/mount/<time>/run.ndjson` (git-ignored).

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
