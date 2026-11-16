# References

Outside sources this project relies on, what each established, and where it is used. Community sources are reverse-engineered: anything they say is checked on the mount before the code depends on it (docs/observations.md).

## Celestron

- **[NexStar Communication Protocol](https://s3.amazonaws.com/celestron-site-support-files/support_files/1154108406_nexstarcommprot.pdf)** (hand control serial commands, 2006). The serial commands discovery and the adapter send through the hand controller: identity, positions, tracking, and pass-through (`P`) to the motor controllers. Predates the Evolution; the discovery traces are the evidence it applies (ADR 0010).
- **[Controlling Backlash in Your Mount](https://www.celestron.com/blogs/knowledgebase/controlling-backlash-in-your-mount)** (knowledge base). Anti-backlash takes up the slack when an axis reverses, for the arrow buttons and as tracking resumes after them; positive compensation applies on a change from backward to forward, negative from forward to backward. "GoTo Approach" (Menu > Scope Setup) is a separate setting for the direction of a goto's final approach.
- **[My backlash settings behave differently before and after alignment](https://www.celestron.com/blogs/knowledgebase/my-backlash-settings-behave-differently-before-and-after-alignment-is-there-a-problem-with-my-mount)** (knowledge base). Anti-backlash and GoTo interact through the motor controllers' feedback loops; it doesn't say how. Measured here instead: anti-backlash doesn't act on pass-through gotos (O14), and does on variable-rate moves (O15).

## Community

- **[NexStar AUX Command Set, Issue 1.0](https://www.astro.louisville.edu/software/xmtel/archive/xmtel-indi-6.0/xmtel-6.0l/support/nexstar/NexStar_AUX_commands_10.pdf)** (February 2003, reverse-engineered). The motor controllers' own commands, which `P` passes through:
  - `MC_GET_POSITION` 0x01, `MC_GOTO_FAST` 0x02, `MC_SET_POSITION` 0x04, `MC_SET_POS_GUIDERATE`/`NEG` 0x06/0x07, `MC_SLEW_DONE` 0x13, `MC_GOTO_SLOW` 0x17, `MC_AT_INDEX` 0x18 and `MC_SEEK_INDEX` 0x19 (azimuth index marker), `MC_MOVE_POS`/`NEG` 0x24/0x25, anti-backlash get/set 0x40/0x41 and 0x10/0x11 (0–99), `MC_GET_APPROACH`/`MC_SET_APPROACH` 0xFC/0xFD.
  - The arrow keys send `MC_MOVE_POS` (right/up) or `MC_MOVE_NEG` (left/down) with the keypad rate 0–9, and rate 0 to stop.
  - Used for: gotos by position (ADR 0014), position and slew-done reads, keypad-rate moves, and discovery's approach and index queries (ADR 0010). It doesn't say which motions anti-backlash applies to.
  - Chapter 5, the GPS at 0xB0. The hand controller asks; the GPS answers. Every request has no data:
    - `GPS_GET_LAT` 0x01 and `GPS_GET_LONG` 0x02: 24 bits, a signed fraction of a full turn, big-endian (`20 3E 35` is +45°20′30.17″, `CA 06 00` is −75°54′16.35″: north and east positive).
    - `GPS_GET_DATE` 0x03: month, day. `GPS_GET_YEAR` 0x04: 16 bits, big-endian (`07 D3` is 2003). `GPS_GET_TIME` 0x33: hours, minutes, seconds. All in GMT.
    - `GPS_TIME_VALID` 0x36 and `GPS_LINKED` 0x37: 1 byte, 1 for yes.
    - `GPS_GET_SAT_INFO` 0x07 (in view, tracked), `GPS_GET_RCVR_STATUS` 0x08, `GPS_GET_HW_VER` 0x55 (answers 0xAB), `GPS_GET_COMPASS` 0xA0 (eight headings), `GPS_GET_VER` 0xFE.
    - Viewing time and site, the hand controller asks time valid, year, date, time, linked, longitude, latitude.
    - Used for: the GPS test (ADR 0020).
- **[libnexstar](https://github.com/indigo-astronomy/libnexstar)** (INDIGO). Model codes newer than Celestron's table (22 = Evolution), and the anti-backlash get and set messages (ADR 0010, ADR 0011).
- **[ZWO forum: ASIAIR and the AUX commands](https://bbs.zwoastro.com/d/12341/1)**. The rate in `MC_MOVE_*` is an index into a table of nine rates (0 stops). ASIAIR sets rate index 1 to 1× sidereal for guiding and sends autoguide pulses as `MC_MOVE_POS`/`MC_MOVE_NEG`, so how anti-backlash acts on fixed-rate moves matters for guiding too.
- **[TwiceAsNice `NexStarAUXScope.h`](https://www2.mpia-hd.mpg.de/~mathar/public/tan_api/NexStarAUXScope_8h.html)** (MPIA). An independent listing of the AUX command IDs (`MC_MOVE_POS` 0x24, `MC_SET_POS_GUIDERATE` 0x06, …) that agrees with the command set above.
- **[platini2/celestron-aux](https://github.com/platini2/celestron-aux)** (GPL-3.0; facts used, no code copied). A scanner and emulators built from captures of real devices and community reverse engineering, not Celestron documentation. Source of the names for 0x0E (StarSense hand controller), 0x17 (dew heater), the motors' 0x05 (get model), and the StarSense camera's messages at 0xB4: 0x3E/0x3F set and get align centre, 0x90 reset capture, 0x91 status, 0x92 capture data, 0x94 start capture, 0x9F image, 0xFE version. Treat the meanings as best guesses. Its GPS emulator (`gps_emulator.py`, `catalog.py`) agrees with Paquette's GPS IDs and layouts, and only answers requests.
- **[ForestTree/nexstar_gps](https://github.com/ForestTree/nexstar_gps)**, forked from [bebrown/nexstar_gps](https://github.com/bebrown/nexstar_gps) (no licence stated; facts used, no code copied). Arduino firmware that stands in for a NexStar GPS module at 0xB0, described in Michael Foegelle's "Arduino GPS Replacement for NexStar GPS" (Orion Ranch Observatory Blog, October 2020). Its replies agree with Paquette's, latitude and longitude scaled by 2²⁴/360. It only answers requests addressed to 0xB0. The blog adds that the AUX port's two data pins are one shared line, and a device that doesn't pull the busy line low risks colliding with other senders.

## Checked on this mount

- The keypad rates' speeds: rates 1–5 run at about half Celestron's list, 6–8 match it, and rate 9 takes 1.3–2.7 s to stop (O16). Anti-backlash acts on keypad moves at rates 1–5, partly at 6 (a fixed amount less than at 5), not at 7 or 8 (O16); on variable-rate moves (O15); not on pass-through gotos (O14).
- The motor controllers' approach setting reads positive on both axes, but pass-through gotos don't use it (O14, O16).
- `MC_AT_INDEX` gets no answer from azimuth: apparently no index marker (O16).
- The AUX bus format, addresses and wiring: ADR 0018, "After the first listen", and building.md.
- The StarSense hand controller (firmware 1.22) doesn't use a GPS (ADR 0020). It never addresses 0xB0, at start-up or after, with a SkySync on the bus (2026-11-11) or with GPS replies pushed every 2 s through its start-up and every 10 s at the main menu (2026-11-16); its time and site didn't change. The Wi-Fi module passes packets with source 0xB0 onto the bus unchanged.

## Not yet confirmed

- What the hand controller does with its "GoTo Approach" setting, and whether ASIAIR's change to rate 1 persists in the motor controller.
