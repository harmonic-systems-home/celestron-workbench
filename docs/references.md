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
- **[libnexstar](https://github.com/indigo-astronomy/libnexstar)** (INDIGO). Model codes newer than Celestron's table (22 = Evolution), and the anti-backlash get and set messages (ADR 0010, ADR 0011).
- **[ZWO forum: ASIAIR and the AUX commands](https://bbs.zwoastro.com/d/12341/1)**. The rate in `MC_MOVE_*` is an index into a table of nine rates (0 stops). ASIAIR sets rate index 1 to 1× sidereal for guiding and sends autoguide pulses as `MC_MOVE_POS`/`MC_MOVE_NEG`, so how anti-backlash acts on fixed-rate moves matters for guiding too.
- **[TwiceAsNice `NexStarAUXScope.h`](https://www2.mpia-hd.mpg.de/~mathar/public/tan_api/NexStarAUXScope_8h.html)** (MPIA). An independent listing of the AUX command IDs (`MC_MOVE_POS` 0x24, `MC_SET_POS_GUIDERATE` 0x06, …) that agrees with the command set above.

## Checked on this mount

- The keypad rates' speeds: rates 1–5 run at about half Celestron's list, 6–8 match it, and rate 9 takes 1.3–2.7 s to stop (O16). Anti-backlash acts on keypad moves at rates 1–5, partly at 6 (a fixed amount less than at 5), not at 7 or 8 (O16); on variable-rate moves (O15); not on pass-through gotos (O14).
- The motor controllers' approach setting reads positive on both axes, but pass-through gotos don't use it (O14, O16).
- `MC_AT_INDEX` gets no answer from azimuth: apparently no index marker (O16).

## Not yet confirmed

- What the hand controller does with its "GoTo Approach" setting, and whether ASIAIR's change to rate 1 persists in the motor controller.
