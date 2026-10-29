# ADR 0011: Setting the hand controller's time and location

**Status:** Accepted

## Context

To orient on the sky, the hand controller needs the date, time and observing site. Typing them on the StarSense keypad is slow and error prone. Celestron's *NexStar Communication Protocol* (ADR 0010) documents Set Time (`H`) and Set Location (`W`), each with a read-back (`h`, `w`). These are the first commands that change the hand controller, and the site is private data (docs/privacy.md).

## Decision

- **A separate crate, `cwb-celestron-setup`,** so discovery stays read-only by construction. It can send only `H`, `W`, `h` and `w`; a test checks every command it sends against that allowlist. None of them moves the mount.
- **Byte layouts** follow the reference and libnexstar's `tc_set_time` and `tc_set_location`:
  - Time: local hour, minute, second, month, day, year − 2000, the standard offset from UTC in whole hours (negative as 256 + offset), then 1 if daylight saving is in effect. Local time includes daylight saving. Zones that aren't whole hours can't be expressed and are refused.
  - Location: latitude degrees, minutes, seconds, then 1 for south; longitude the same, then 1 for west. Whole arcseconds, about 30 m.
- **Time source:** the Mac's clock, sent on a whole second. The time zone is the Mac's unless the site file names one.
- **Site source:** the newest precise phone fix in the database (ADR 0012), or `config/site.local.toml`, git-ignored by the `*.local.*` rule, or a file named with `--site` or `CWB_SITE`. The committed template `config/site.example.toml` holds placeholders the tool refuses. Coordinates are never printed, logged or written to a report: `Debug` hides them, parse errors give only a line number, and the confirmation shows only the site name and hemispheres.
- **Confirm, then verify:** `cwb celestron setup` checks the hand controller answers, shows what it will send, and asks before sending unless given `--yes`. After each set it reads the value back. Time must agree within 2 s; location must match exactly. A read-back result says only whether the values match, never what they are.

## Consequences

- Each observing session starts with one command instead of keypad entry.
- The reference lists these commands from hand controller version 2.3. The StarSense numbers its firmware differently (ADR 0010), so the read-back, not the version, shows whether they work.
- The terminal shows the time zone name. That's coarse, but it's worth knowing before pasting the output anywhere.
