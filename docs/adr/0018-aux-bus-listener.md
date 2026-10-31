# ADR 0018: A listen-only AUX bus monitor, as a Mac app

**Status:** Accepted

## Context

ADR 0016 sets out to find whether several controllers on the AUX bus can lock up the hand controller or stop moves working, and notes that we see only effects: the hand controller doesn't pass other controllers' traffic back to us. Listening to the bus itself shows every command: the keypad's, SkySafari's (through the Evolution's Wi-Fi module), ASIAIR's (through the hand controller), ours, and the motor controllers' replies.

As the community describes it (references.md; INDI's Celestron AUX driver, nexstar-arduino): the AUX ports carry TTL serial at 19,200 baud, 8N1, 0–5 V; the two data pins are wired together, a single half-duplex line pulled high in the mount; a select line, also pulled high, is pulled low by a device to send. Packets are `0x3B`, length, source, destination, message ID, data, checksum (two's complement of the sum from length on). Device addresses include the hand controller (0x04, 0x0d), azimuth (0x10), altitude (0x11) and the Wi-Fi module (0xb5). Not yet checked on this mount.

The operator will use it at night, outdoors, with a MacBook and no table: no typing, readable in the dark, nothing to configure.

The hardware is a USB-to-TTL cable (FTDI FT232R, 3.3 V logic) and an RJ12 breakout on a free AUX port, wired **receive-only**: the cable's RXD through a 10 kΩ resistor to a data pin, ground to ground, VCC and TXD taped off. The resistor protects the 3.3 V input if the bus is 5 V and barely loads the bus. The pinout is found with a meter first; one pin carries +12 V.

## Decision

### A Mac app in Swift, with the logic in a tested package

One Swift package, `macos/AuxListener/`, with two targets:

- **`AuxListenerCore`** (a library, tested with `swift test`): packet framing from a byte stream with resynchronization on `0x3B`, checksum checking, decoding of devices and the message IDs we know (references.md), request/reply pairing, and anomaly detection: bad checksums, broken or truncated frames, bytes between frames, and requests without a reply within a configured time. Also the session log writer and the serial port (POSIX `termios`, 19,200 8N1, read-only: the app never writes to the port).
- **`AuxListener`**: the SwiftUI Mac app, built as a Swift package executable so it needs no Xcode project, and a script that wraps it into an `.app` for the Dock. It runs unsandboxed, as serial ports need.

### No typing, and dark

- **Starts listening on its own:** it finds the FTDI cable by its USB vendor ID (0x0403) and opens it, ignores the hand controller's Prolific cable, and reconnects after an unplug. Recording starts when listening does; there is nothing to set.
- **Night palette:** dark red on black throughout, large type, no white anywhere.
- **Big buttons for marks**, each a timestamped event in the log: *Keypad*, *SkySafari*, *ASIAIR*, *Problem*, *Recovered*, *Re-plugged USB*, *Power cycled*. The set is configurable.
- **The live view:** whether the cable is connected and the bus active; per device, its last command and reply; packets per second; anomaly counts that turn bright when one occurs; time since the last packet. A scrolling feed of decoded packets, with position polling hidden by default so commands stand out.
- **An alert sound** on an anomaly, so a problem is noticed without looking; a setting turns it off.
- **Demo traffic** while no cable is connected: made-up packets from several devices, with the odd anomaly, so the app can be tried without the hardware. Marked DEMO on screen and never recorded.

### The log

- **NDJSON, one file per session**, in the data folder that config points to (git-ignored; never committed). Each packet: the raw bytes in hex, so it can always be decoded again; the decoded fields; and its time on the Mac's monotonic clock and in UTC. Marks, anomalies, connects and disconnects are events in the same file.
- **Matching other logs:** by UTC to the runner's logs and the phone's session (through ADR 0015's `clock` events, which pair the runner's clock with UTC). `cwb` gains a reader for these logs later, so the mount report can include bus traffic.

### Safety and privacy

- **Receive-only in hardware and software:** TXD isn't connected, and the app never opens the port for writing. Nothing it does can affect the mount.
- **Bus traffic isn't private**, but session logs are real data: they stay in the data folder. Tests use synthetic byte streams under `fixtures/`.

### Order of work

1. **Core:** framing, decoding and anomaly detection, tested on synthetic streams: clean traffic from several devices, a corrupted checksum, a frame cut short, two packets run together, a request without a reply, noise between frames.
2. **App:** port discovery and reading, the live view, marks and the log; checked with a fake byte source and then the real cable on the bench.
3. **First listen on the mount:** meter the breakout, wire it, then listen with the hand controller alone, then the keypad, then SkySafari: ADR 0016's ladder, steps 1–4, with the decoded commands in view.

## Consequences

- ADR 0016's "we see effects, not commands" no longer holds: every controller's commands and every reply can be seen and timed, so collisions and unanswered requests show directly.
- A second Swift package and app to maintain, separate from the runner (still a command line in Rust). The packet formats are documented in one place (references.md and this ADR) so the Rust reader can't drift.
- The community's protocol details become checked facts or corrections once the first listen runs.
- A step towards the board idea (a permanent AUX-port monitor with Wi-Fi), which would reuse the Core package.
