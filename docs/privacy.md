# Privacy

This repository is public. The data this project produces is not.

## What stays out of the repo

| Category | Examples | Where it comes from |
|---|---|---|
| Observing location | Latitude/longitude, elevation, site names | Site config, alt/az math, plate solves, FITS headers (`SITELAT`, `SITELONG`, `OBSGEO-*`), ASIAIR exports |
| Photo metadata | GPS location and device info embedded in images | Attachment and fixture photos, especially from an iPhone |
| Device identifiers | iPhone UDID, `identifierForVendor`, mount/hand controller/StarSense serial numbers | Session manifests, device tables, discovery traces |
| Home network | Wi-Fi network names, LAN IPs, MAC addresses, hostnames | Logs, connection settings, the manifest's host info |
| Apple developer account | Team ID, provisioning profiles, signing identities | Xcode project settings |
| Raw sessions | SQLite databases, NDJSON logs, reports, images | Every recording |

## Where it lives instead

- **Real data:** a separate private repo (`harmonic-systems-home/celestron-workbench-data`), or a local data folder outside this repo. Point the tools at it with a config file or environment variable. Never hard-code the path.
- **Session sites:** each session records the phone's location fix and an indoor/outdoor choice (ADR 0012). They live in the local database, the phone's session files and exports, all private. Logs, `Debug` output and terminal output never show coordinates.
- **Site and signing config:** git-ignored local files (`config/site.local.toml`, `Local.xcconfig`). Commit a `*.example` template with placeholder values beside each one.
- **Fixtures:** only synthetic sessions, or real sessions that went through the sanitizer.

## Sanitizer requirements (to build with the CLI)

Before a real session can be promoted to `fixtures/`:

- Replace device and session identifiers with salted hashes. Keep the salt in the private data store.
- Replace site coordinates with a fixed fictitious site. If the analysis needs real geometry, shift all coordinates consistently.
- Drop host names, IPs, network names and serial numbers from manifests and raw responses.
- Strip all image metadata. Re-encode images rather than copying them.
- Record that sanitization happened, and with which version, in the fixture's manifest.

### Simulator scenes from the owner's own images (2026-11-20)

The owner's own Moon images (DWARF stacks and others) may be committed as
simulator scenes under `fixtures/scenes/`, released under **CC0**. The owner wants
their stacking metadata kept, so for these images, and only these, the rule
"strip all image metadata" is replaced by:

- **Location rounded** to whole degrees of latitude and longitude (about 100 km),
  in every field that holds it: EXIF GPS, XMP, FITS-style keywords, and any
  vendor or stacking fields. Altitude above sea level is removed.
- **Everything else kept** (capture time, exposure, gain, stacking details),
  except device and camera **serial numbers** and other unique identifiers,
  which are removed.
- The metadata is rewritten without re-encoding the pixels where the format
  allows. A tool lists every metadata field before and after, and the owner
  reviews the list before the image is committed.
- The rounded location, the time and the licence go in the scene's sidecar as
  well, for the simulator.

## Automated checks

- `scripts/privacy-check.sh` scans files for coordinate-like values, MAC addresses, private IPs, Apple Team IDs, UDIDs and FITS site keywords.
- `.githooks/pre-commit` runs it on staged files. Enable it with `git config core.hooksPath .githooks`.
- CI runs it on the whole repo for every push and pull request.

For a deliberate, safe match (such as an example value in documentation), add the marker `privacy-check: allow` on the same line.
