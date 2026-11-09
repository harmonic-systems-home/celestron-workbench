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
- **Night palette:** dark red on black throughout, large type, no white anywhere, from civil dusk to dawn (the Sun 6° down at the site Moon Mosaic saved, or 19:00–07:00 without one); ordinary light colours by day, when red on black is hard to read. A setting fixes it to day or night.
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

## After the first listen

The first listen on the mount, with the hand controller's arrow keys:

- **Confirmed:** 19,200 baud, the `3B` packet format and checksum, azimuth at 0x10 and altitude at 0x11, keypad moves as `MC_MOVE_POS`/`MC_MOVE_NEG` with rate 0 to stop, and the wiring (building.md). The StarSense hand controller sends from 0x0E, which wasn't in the list above.
- **USB timing:** bytes reach the Mac in batches about 16 ms apart, and one reply was split across 33 ms. A frame is now cut short only after 50 ms of quiet, not 20 ms. Times between packets, such as reply latency, are only good to about 16 ms, so they can't show fine timing or prove collisions.
- **Accessories:** at startup the hand controller asks for accessories that may not be fitted (the focuser at 0x12, the dew heater at 0x17) and for the StarSense camera before it's ready. A request to a device not yet heard from this session is no longer a "no reply" anomaly; a motor must always answer.
- **StarSense:** messages to and from 0xB4 use community names (references.md), which are best guesses; the app decodes the align centre and status replies. 0x05, which the hand controller sends about every 5 s until the camera answers `01` and then stops, is unknown; it looks like a readiness check. Bulk star lists appear to use a separate `3C` frame the app doesn't decode, so they would count as stray bytes; not yet seen on this mount.
- **Late answers:** a device's unmatched message to a controller is a late reply, not a new request; the camera's first answer took 1.09 s. It's marked "late" with no latency.
- **Idle and stops:** with only the hand controller connected, the bus is silent between its startup and a key press, so regular traffic comes from another controller. The arrow keys stop with `MC_MOVE_POS` at rate 0 whichever way the move went.
- **Probes repeated with checksum `00`:** after most unanswered probes to 0x12 or 0x17 at startup, the same frame comes about 0.5 s later with `00` in place of the checksum. It came exactly four times, in the same places, in three sessions (the third through the soldered cable), never among moves, so it's hand controller behaviour, not the cable; why it does it is unknown. The listener logs it as a `known` event (`probe_checksum_00`) and shows it dimmed, without counting it or sounding the alert, but only when every byte but the last matches a request from a controller, to an accessory not heard from, in the last 2 s. Anything else ending `00` is still a bad checksum.

## SkySafari over Wi-Fi (2026-11-09)

The first listen with SkySafari Pro on an iPad, connected through the Evolution's own Wi-Fi ("Celestron Wi-Fi" in SkySafari), the hand controller idle:

- **Its packets come from 0x20, not 0xB5:** the Wi-Fi module puts the app's packets on the bus under the app address. The listener names 0x20 "App (Wi-Fi)".
- **On connecting** it reads both motors' version and model, stops both axes, reads the StarSense camera's version and align centre, probes the focuser and an unknown 0xB9 (neither answers), reads the lights, charger and battery, reads the anti-backlash values and approach, and sets the guide rate to 0 on both axes. It doesn't start a StarSense alignment. Then it polls both axes' positions about every 0.5 s and the battery about every 5.5 s for as long as it's connected.
- **Moves** are `MC_MOVE_POS`/`MC_MOVE_NEG` and a stop at rate 0, as from the keypad. SkySafari's rates 1, 2, 3 and 4 send rates 2, 5, 7 and 9 (checked one rate at a time, the same day). In the first session every move was rate 9, so its setting was 4; two moves that barely moved were taps stopped about 16 ms after starting.
- **Split packets:** 24 times in about 4 minutes, one of SkySafari's packets stopped after its first two or three bytes (`3B`, the length, and usually `20`) and a whole reply to an earlier request, from a motor or the battery, came in the gap before the rest. The split point is the same every time, so it looks like how the Wi-Fi module sends, not noise. The listener now recognises a frame whose checksum fails, finds a `3B` inside it, and checks that the bytes make two valid packets: the inner one and the outer one with the inner removed. If they do, both are decoded and a `known` event `split_packet` keeps the raw bytes; if not, it stays a bad checksum and the following bytes are framed again. Replaying the session, 23 of the 24 decode this way; the other, during the guide-rate commands, seems to be two splits overlapping and stays a bad checksum.
- **SkySafari's Align button** (StarSense set to Auto in its Scope Setup, the camera capped) took one capture where the tube pointed, with no slews, talking to the camera directly; the hand controller sent nothing. SkySafari sent `RESET_CAPTURE [03 E8 00]` (answered 2.8 s later), `START_CAPTURE [00]` (answered `[09 09]` 5.0 s later) and `GET_CAPTURE_DATA` (answered `[09 09]`, followed at once by a `3C` frame), then reported that the alignment failed. So SkySafari runs its own StarSense alignment, apart from the hand controller's, as the operator found before: an alignment made in one isn't used by the other.
- **The `3C` frame:** `3C`, a 4-byte big-endian data length (72), the data, and a checksum made as for packets (from the first length byte on); checked on this one frame. From the fourth data byte on, the data reads as 16 big-endian floats from 41 to 1631, perhaps pixel positions of spots found in the capped image. The listener frames it by this length and checksum and logs it raw as a `known` event `bulk_3c`, not decoded until a capture with stars is seen. A `3C` whose length is over 4096 is a stray byte.
- **Captures take seconds,** so `RESET_CAPTURE` and `START_CAPTURE` wait 10 s for an answer before "no reply"; other messages keep 0.5 s.
- **Not yet known:** whether the device addressed by a split packet receives it whole (the listener sees the bus at one AUX port, and a split request's answer may be the next poll's), and whether the hand controller ever receives one. A split request that goes unanswered now shows as "no reply", so later sessions answer the first; ADR 0016 has the second.

## Consequences

- ADR 0016's "we see effects, not commands" no longer holds: every controller's commands and every reply can be seen and timed, so collisions and unanswered requests show directly.
- A second Swift package and app to maintain, separate from the runner (still a command line in Rust). The packet formats are documented in one place (references.md and this ADR) so the Rust reader can't drift.
- The community's protocol details become checked facts or corrections once the first listen runs.
- A step towards the board idea (a permanent AUX-port monitor with Wi-Fi), which would reuse the Core package.
