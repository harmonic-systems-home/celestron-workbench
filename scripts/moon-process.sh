#!/usr/bin/env bash
# Stacks and stitches a Moon mosaic session into <session>/mosaic.tif
# (ADR 0019, step 6): Planetary System Stacker per tile, then Hugin seeded
# from the session log. Run on the desktop Mac.
#   scripts/moon-process.sh <session folder> [--quick] [--pss PATH] [--hugin DIR]
#     --quick       stack with the script's own quick stack instead of PSS
#     --pss PATH    PlanetarySystemStacker (default ~/venvs/pss/bin/…, or $PSS)
#     --hugin DIR   Hugin's command-line tools (default
#                   /Applications/Hugin/tools_mac, or $HUGIN_TOOLS)
# Needs uv (brew install uv); it fetches numpy and tifffile on first run.
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
if ! command -v uv >/dev/null; then
  echo "Needs uv: brew install uv" >&2
  exit 1
fi
# A native Python (uv may otherwise pick an Intel one under Rosetta).
arch="$(uname -m | sed 's/arm64/aarch64/')"
exec uv run --quiet --python "cpython-3.10+-macos-$arch-none" --script \
  "$here/moon_process.py" "$@"
