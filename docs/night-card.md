# Night card

A one-page sequence for a night at the telescope: the StarSense hand controller's keys and the Workbench apps, in order. The StarSense steps come from Celestron's *StarSense AutoAlign* manual (item 94005, revision 2-16); page numbers are that manual's. That manual is from 2016 and our hand controller runs firmware 1.22, so a menu name may differ slightly.

**OPTION** is the Celestron logo key, bottom left.

## Before leaving the house

- [ ] Mount battery charged. A day of indoor testing can leave it flat.
- [ ] Laptop charged. The AUX Listener and Moon Mosaic keep it awake while recording or connected. Closing the lid still puts it to sleep.
- [ ] Caps off every eyepiece and extender, including any hidden inside the 2″ extender.

## Power-up

1. Plug the hand controller into the mount, then plug the USB cable into the laptop. The StarSense camera must be connected, and the mount cable must go in first: otherwise the hand controller stalls at start-up looking for the camera. To restart a frozen hand controller, unplug both and plug them back in, mount first.
2. Wait for **"StarSense Ready"** (about 30 s).
3. Open the AUX Listener, then connect Moon Mosaic. Check its log for **"Hand controller time: confirmed; site: confirmed."**
4. Keep SkySafari and every other Wi-Fi client off. All six freezes on 2026-11-09 happened while something was using the mount's Wi-Fi.

## Time and site prompts (p.11)

The hand controller has no running clock: at start-up it shows the date, time, zone and DST last saved, and the time hasn't moved on (O19).

- **Hand controller only:** enter the time and date. The zone, DST, year and site stay as saved.
- **Moon Mosaic connected:** it has already set them, so accept them. (Moon Mosaic itself doesn't need the hand controller's time; only the hand controller's own GoTos and alignment do.)
- **Planets:** Moon Mosaic sets the time and site, StarSense aligns, the hand controller goes to the planet, and ASIStudio captures.
- **If the zone shows a strange character, or the date is days off,** an app set the time last session and it wasn't saved: re-enter every field.

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

The old alignment no longer fits. Clear it, then start a new one; don't add points to it.

- **Clear it:** **OPTION + BACK** together clears alignment data. This comes from Celestron's firmware notes for 1.17 and 1.18, not the manual. The notes list it beside saved alignments, so it may clear a saved slot rather than the current alignment: try it once at home to see which screen it works on.
- The Align menu also has **Reset Alignment**. The manual doesn't describe it, so test it once before relying on it.
- Then run **StarSense Auto** or **Manual** again from the start.
- Changing the location in the menu also drops the alignment (p.24).

## If the hand controller freezes

Save the alignment to a slot as soon as it's good (see Save / Load Align above). Then a freeze costs one camera image, not a new alignment, as long as the tripod hasn't moved:

1. Unplug the hand controller and its USB cable, and plug them back in, mount first.
2. At StarSense Ready, **Load** the slot and sync with **Camera**, as above.

## Camera calibration (p.12)

Only needed if the StarSense camera has been bumped or rotated. It needs an alignment first.

1. **STARS**, **Named**, then pick a star of magnitude 2 or brighter and press ENTER to slew to it.
2. Low-power eyepiece: get the star in view with the arrow keys and press **ENTER**.
3. High-power eyepiece: centre the star, finishing UP/RIGHT, and press **ALIGN**.
4. At **"Solution Found"**, press **ENTER**. At "Realignment Required", run StarSense Auto again from where the tube is.

## Ending the night

- **If Moon Mosaic, ASIAIR or anything else set the time tonight:** before powering off, open the hand controller's time screen and press ENTER through every field without changing anything. That saves a clean copy; otherwise the next start-up shows scrambled values (O19).
- To keep the alignment for the next session: MENU, **Telescope**, **Hibernate** (p.23). Put the tube where you want it, press ENTER and power off without moving it. Next time, at "Wake Up" press ENTER, confirm the time and site, and press ENTER again.
- Disconnect Moon Mosaic, then stop the AUX Listener, before unplugging cables.
- Copy the night's recordings to the private data repo.
