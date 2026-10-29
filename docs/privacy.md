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
- **Site and signing config:** git-ignored local files (`config/site.local.toml`, `Local.xcconfig`). Commit a `*.example` template with placeholder values beside each one.
- **Fixtures:** only synthetic sessions, or real sessions that went through the sanitizer.

## Sanitizer requirements (to build with the CLI)

Before a real session can be promoted to `fixtures/`:

- Replace device and session identifiers with salted hashes. Keep the salt in the private data store.
- Replace site coordinates with a fixed fictitious site. If the analysis needs real geometry, shift all coordinates consistently.
- Drop host names, IPs, network names and serial numbers from manifests and raw responses.
- Strip all image metadata. Re-encode images rather than copying them.
- Record that sanitization happened, and with which version, in the fixture's manifest.

## Automated checks

- `scripts/privacy-check.sh` scans files for coordinate-like values, MAC addresses, private IPs, Apple Team IDs, UDIDs and FITS site keywords.
- `.githooks/pre-commit` runs it on staged files. Enable it with `git config core.hooksPath .githooks`.
- CI runs it on the whole repo for every push and pull request.

For a deliberate, safe match (such as an example value in documentation), add the marker `privacy-check: allow` on the same line.
