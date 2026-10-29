# ADR 0010: Read-only Celestron discovery through the hand controller's serial port

**Status:** Accepted

## Context

Before any code can move the NexStar Evolution (ADR 0005 hardware gate), the exact connection path has to be inventoried and a protocol compatibility report reviewed (plan Prompt 7). The Evolution offers two command paths from a Mac: its built-in Wi-Fi, and the NexStar+ hand controller's USB port.

Over Wi-Fi the mount speaks its internal motor bus protocol, known mostly from community reverse engineering, and adds a second wireless hop with the same delays and dropouts already measured for the phone (up to 1.1 s, assumptions N1). The safety design relies on stop commands arriving promptly. Through the hand controller, the mount speaks Celestron's published serial protocol over a wire, which is also the plan's preferred path.

## Decision

- **Path:** the hand controller's serial port over USB, 9600 baud, 8N1. A Wi-Fi adapter can be added later behind the same traits.
- **Reference:** Celestron's *NexStar Communication Protocol*, as hosted on Celestron's support site. It dates from 2006 and predates the Evolution, so the discovery traces are the evidence that it applies. Model code 22 (Evolution) comes from libnexstar, since Celestron's table stops at 12.
- **Read-only by construction:** discovery lives in its own crate, `cwb-celestron-discovery`. The only sendable type is a `Query` enum of documented "get" commands: echo, versions (hand controller and both motor controllers), model, alignment, goto in progress, tracking mode, and axis positions. There's no variant for motion, goto, sync or any setter, and no way to send raw bytes. A test checks every sendable byte sequence against an allowlist.
- **Private data stays out:** get location (`w`), GPS position and time queries are never sent. Port listings drop USB serial numbers, and reports redact them from device paths. Reports go to the git-ignored `reports/discovery/` by default.
- **The report** (`cwb celestron discover`) records every exchange byte for byte (hex, outcome, latency), checks identity, motors, goto, tracking, position steadiness and reply latency against the 300 ms acknowledgement deadline, and lists the commands proposed for the hardware adapter. Each proposed command maps to a section of the reference, or is marked for observation on hardware.
- **Behind the mount-core trait:** read-only queries are the `MountQueries` trait (identity, axis positions) in `mount-core`. The discovery hand controller implements it now; the Prompt 8 adapter implements it alongside `MountAdapter`.

## Consequences

- The documented slew commands are open-ended: an axis keeps moving until a stop arrives. The controller's lease always sends the stop, but a lost serial link leaves the axis moving, so the power switch (ADR 0005 layer 1) stays the real stop.
- A `#` reply only means the hand controller relayed a command. Motion is confirmed by the IMU, never by the reply.
- Several behaviours aren't settled by any document and are observed in the first hardware trials: the slowest effective rate, onset and stop delays, whether a fixed-rate stop ends a variable-rate slew, keypad interference, and whether Celestron's slew limits apply to pass-through slews.
- The mount's own axis positions (`z`, 0.077″ units, relative to power-on until aligned) give a second motion record to compare with the IMU.
