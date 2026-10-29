# ADR 0012: Each session records where it took place

**Status:** Accepted

## Context

Characterization results depend on where the phone was: indoors and outdoors differ in temperature, magnetic disturbance and GPS quality. The hand controller also needs the observing site after every power cycle (ADR 0011), and typing it is error prone. The phone has GPS; the Mac has none, and its Wi-Fi positioning fails at a dark site.

The privacy rules (docs/privacy.md) keep coordinates out of the public repo. Session data never goes there: it lives in the local database and the private data store. So sessions may hold the site, as long as fixtures, logs and shared reports don't.

## Decision

- **A `site` message,** phone to Mac, once per session shortly after recording starts. It carries a random `site_id` (so a resend is harmless), the phone time of the fix, the operator's environment choice (indoor, outdoor or unspecified), a location status, and the fix when there is one: latitude, longitude, horizontal accuracy, altitude and vertical accuracy when known, whether iOS allowed precise location, and the fix's age.
- **Location status:** `fix`; `off` when the operator turned Record location off in the app; `denied` when iOS access was refused or restricted; `unavailable` when no fix arrived in 20 s. The schema requires a location exactly when the status is `fix`.
- **On the phone:** the Settings section has Where (indoors, outdoors, not specified) and Record location (on by default). The app asks for When In Use access the first time, listens until a fix is within 10 m or 20 s pass, and keeps the most accurate fix. The live view shows the accuracy, never the coordinates.
- **On the Mac:** the `session_sites` table (migration 0004) stores it; export and import carry it; `cwb session list` shows the environment. Receiver logs show the environment and status only.
- **Setting the hand controller:** `cwb celestron setup` takes the location from the newest precise phone fix within 100 m accuracy (`--location-from auto`, the default, when `--db` or `CWB_DB` is given), else from the site file. `--location-from phone` or `site-file` forces one source.
- **Keeping coordinates private:** `Debug` output of a location hides them; nothing logs or prints them; the sanitizer must replace them before a session becomes a fixture. Shared examples and tests use fictitious sites.

## Consequences

- The environment is the operator's statement. GPS accuracy is only a hint: indoors it is usually tens of meters, outdoors a few meters.
- Exports (`cwb session export`) and the phone's session files now contain the site. They were already private data; treat them that way when sharing.
- A session stopped before the fix arrives has no site.
