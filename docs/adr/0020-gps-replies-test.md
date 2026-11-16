# ADR 0020: Testing whether the hand controller takes GPS replies

**Status:** Accepted. Tested 2026-11-16: the StarSense hand controller ignores GPS replies.

## Context

A SkySync GPS was added to the AUX bus so visual sessions wouldn't need the laptop to set the time and site (ADR 0011). On 2026-11-11 the AUX Listener showed the StarSense hand controller never addressing the GPS (0xB0): at two start-ups it probed the camera, both motors, the focuser and the dew heater, and at the alignment the motors and battery, but nothing went to 0xB0. The StarSense hand controller has no Utilities menu, where the NexStar+ turns its GPS on.

In the community's accounts (docs/references.md) a GPS only answers: the hand controller asks if it's linked and its time is valid, then for the year, date, time, longitude and latitude, and the GPS replies to each. So the open question is whether the StarSense hand controller acts on those replies at all: when it asks, or when they arrive unasked.

The Evolution's Wi-Fi module bridges TCP port 2000 to the bus (ADR 0018), so a laptop can put packets on the bus without new hardware.

## Decision

- **A separate crate, `cwb-aux-gps`,** and `cwb celestron gps-test`. It speaks as the GPS through the Wi-Fi module for a set time: every few seconds it pushes the seven replies a hand controller asks for when it views time and site, and it answers any GPS request it hears, from a hand controller only.
- **Only GPS replies can be sent.** The one packet constructor builds source 0xB0, a hand controller as destination (0x04, 0x0D or 0x0E), and one of the GPS reply IDs. A test checks every ID and destination. Nothing can address a motor, so nothing can move the mount, and the motion lock (CLAUDE.md) is untouched.
- **A decoy location, always:** the Royal Observatory, Greenwich. The crate has no way to send another place, so the site never reaches the bus or a trace. The time is a decoy too (2030-01-01 12:00 UTC) by default, so a change shows; `--time now` sends this Mac's clock.
- **Evidence:** the AUX Listener records the bus (did the packets arrive as sent, from 0xB0? did the hand controller react?), the tool's trace records what it sent and heard, and the hand controller's display shows its time and site afterwards. The mount's address isn't printed or traced.
- **The test, in the office:**
  1. Real GPS unplugged, listener recording.
  2. At the main menu, run `cwb celestron gps-test` for a minute, then check the time and site.
  3. With the mount on, unplug the hand controller and its USB, start the test, and plug the hand controller back in: it starts while the replies are going out, which is when it would consult a GPS.

## Consequences

- If the hand controller takes the time or site, the listener will have the exact packets, and a small board on the AUX port or the mount's Wi-Fi can send them at power-up.
- If it ignores them, time and site go through its USB port only (ADR 0011), and the board has to sit there instead.
- Unknown: whether the Wi-Fi module passes packets that claim another source than the app's 0x20. The listener shows it either way. The earlier hand controller freezes all came under Wi-Fi polling (ADR 0018); these runs are short, and each one doubles as a re-test on the 7.19 motor firmware.

## Outcome (2026-11-16)

The office test, run from a Mac on the mount's Wi-Fi with the AUX Listener recording and the SkySync unplugged:

- **The Wi-Fi module passes the replies.** Every reply reached the bus byte for byte, with source 0xB0. It doesn't echo them back to the sender, but it did pass back some of the hand controller's start-up traffic.
- **At the main menu,** the hand controller sent nothing in response to 21 replies over 15 s. An earlier minute-long run doesn't count: the hand controller was stalled then.
- **At start-up,** with replies pushed every 2 s for 3 minutes and the hand controller plugged in partway, it probed the camera, both motors, the focuser and the dew heater, as before, and never addressed 0xB0.
- **Its time, date and site didn't change** in either test.

So the StarSense hand controller (firmware 1.22) has no GPS support, and a board that sets time and site has to use its USB port (ADR 0011), not the AUX bus.

Two things to know for later:

- **Connections too close together.** A connection to port 2000 made just after another one closed (a reachability check, then the test) was twice either dropped at once or accepted with nothing reaching the bus. With a few seconds between them it worked every time.
- **A stall without the camera.** Since the firmware update, the hand controller stalls at start-up when the StarSense camera is unplugged, and a stalled one answers nothing. Keep the camera connected for any test.

