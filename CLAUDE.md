# Celestron Workbench

The build spec is [docs/plan.md](docs/plan.md). Work through its prompts in order and stop after each one for review. Hardware motion stays disabled until the simulator safety suite and the operator checklist pass.

## Public repo: privacy rules

This repo is public. Follow [docs/privacy.md](docs/privacy.md):

- Never commit real session data, observing site coordinates, device or mount serials, UDIDs, network details, Apple Team IDs or photos with location metadata.
- Real data lives in the private `harmonic-systems-home/celestron-workbench-data` repo or a local data folder that config points to. Never hard-code its path.
- Keep personal settings in git-ignored `*.local.*` / `Local.xcconfig` files, with a committed `*.example` template beside each.
- Commit only synthetic or sanitized data under `fixtures/`.
- Run `scripts/privacy-check.sh` before committing; the pre-commit hook needs `git config core.hooksPath .githooks`.
