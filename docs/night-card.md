# Night card

A one-page sequence for a night at the telescope: the StarSense hand controller's keys and the Workbench apps, in order. The StarSense steps come from Celestron's *StarSense AutoAlign* manual (item 94005, revision 2-16); page numbers are that manual's. That manual is from 2016 and our hand controller runs firmware 1.22, so a menu name may differ slightly.

**OPTION** is the Celestron logo key, bottom left.

## Before leaving the house

- [ ] Mount battery charged. A day of indoor testing can leave it flat.
- [ ] Laptop charged. The AUX Listener and Moon Mosaic keep it awake while recording or connected. Closing the lid still puts it to sleep.
- [ ] Caps off every eyepiece and extender, including any hidden inside the 2″ extender.

## Power-up

1. Plug the hand controller into the mount, then plug the USB cable into the laptop. To restart a frozen hand controller, unplug both and plug them back in, mount first.
2. Wait for **"StarSense Ready"** (about 30 s).
3. Open the AUX Listener, then connect Moon Mosaic. Check its log for **"Hand controller time: confirmed; site: confirmed."**
4. Keep SkySafari and every other Wi-Fi client off. All six freezes on 2026-11-09 happened while something was using the mount's Wi-Fi.

## Time and site prompts (p.11)

Moon Mosaic has already set them, so accept them.

- At the time/date/location screen, **BACK accepts** and **ENTER edits**.
- If it asks anyway:
  - **Time source:** ENTER.
  - **Time and date:** ENTER through each field. Time is 24-hour HH:MM:SS; the date is MM/DD/YYYY.
  - **Time zone and DST:** scroll keys (6 and 9) to change, ENTER to accept.
- At **"Set Align Start"**, check the tube is level, pointing at the horizon, and press ENTER.

## Aligning

**StarSense Auto (p.11):**
1. ALIGN, **StarSense Auto**, ENTER.
2. The mount slews to several areas of sky. Don't touch it or shine a light near the camera.
3. At **"Alignment Complete"**, press ENTER.

**StarSense Manual (p.13):** always three points, taken in order.
1. ALIGN, **StarSense Manual**, ENTER.
2. Point 1: aim at clear sky, finishing with **UP then RIGHT** until the checkmark shows. Press **ENTER** ("Acquiring Image").
3. Point 2: slew to a new area, finish UP/RIGHT, **ENTER**.
4. Point 3: slew as far as you can from point 1, finish UP/RIGHT, **ENTER**. It's aligned after the third image.

**Numbered slots** belong to **Save / Load Align** (p.15), a separate menu, not to the alignment itself:
- **Save:** at StarSense Ready, ALIGN, **Save / Load Align**, ENTER. Pick a slot (0–9) with the scroll keys, then press **OPTION + ENTER** together. The slot is named with the date and time.
- **Load:** pick the slot and press **OPTION + ALIGN** together. At "Sync Reference", choose **Camera** and press ENTER. Aim at open sky, finish UP/RIGHT and press ENTER.

**Adding a point** (p.14): ALIGN, **Add Align Ref**, ENTER. Slew several degrees away, finish UP/RIGHT, ENTER. Up to 10 points in total.

## After moving the mount

The old alignment no longer fits. Don't add points to it; start a new one.

- Run **StarSense Auto** or **Manual** again from the start. The manual doesn't say outright that this replaces the old model, but it treats a new Auto run as a fresh alignment.
- The Align menu also has **Reset Alignment**. The manual doesn't describe it, so test it once before relying on it.
- Changing the location in the menu also drops the alignment (p.24).

## Camera calibration (p.12)

Only needed if the StarSense camera has been bumped or rotated. It needs an alignment first.

1. **STARS**, **Named**, then pick a star of magnitude 2 or brighter and press ENTER to slew to it.
2. Low-power eyepiece: get the star in view with the arrow keys and press **ENTER**.
3. High-power eyepiece: centre the star, finishing UP/RIGHT, and press **ALIGN**.
4. At **"Solution Found"**, press **ENTER**. At "Realignment Required", run StarSense Auto again from where the tube is.

## Ending the night

- To keep the alignment for the next session: MENU, **Telescope**, **Hibernate** (p.23). Put the tube where you want it, press ENTER and power off without moving it. Next time, at "Wake Up" press ENTER, confirm the time and site, and press ENTER again.
- Disconnect Moon Mosaic, then stop the AUX Listener, before unplugging cables.
- Copy the night's recordings to the private data repo.
