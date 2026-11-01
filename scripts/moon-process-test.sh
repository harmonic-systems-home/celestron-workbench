#!/usr/bin/env bash
# Tests scripts/moon-process.sh on a synthetic session (ADR 0019, step 6):
# MoonMosaicSynth writes SER tiles of the fake camera's Moon (aiming errors,
# drift, jitter, noise), the session log and the truth; the script stacks and
# stitches them; moon_process_check.py scores the mosaic against the truth.
#   scripts/moon-process-test.sh [--pss]   (--pss also runs the PSS route)
set -euo pipefail

root="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
pkg="$root/macos/MoonMosaic"
arch="$(uname -m | sed 's/arm64/aarch64/')"
work="$(mktemp -d "${TMPDIR:-/tmp}/moon-process-test.XXXXXX")"
trap 'rm -rf "$work"' EXIT

"$root/scripts/mount-ffi-lib.sh" >/dev/null
swift build --package-path "$pkg" -c release --product MoonMosaicSynth >/dev/null
"$(swift build --package-path "$pkg" -c release --show-bin-path)/MoonMosaicSynth" "$work/session"

check() {
  uv run --quiet --python "cpython-3.10+-macos-$arch-none" --script \
    "$root/scripts/moon_process_check.py" "$work/session"
}

echo "== Quick stack"
"$root/scripts/moon-process.sh" "$work/session" --quick
check

if [ "${1:-}" = "--pss" ]; then
  echo "== Planetary System Stacker"
  rm -rf "$work/session/processing" "$work/session/mosaic.tif"
  "$root/scripts/moon-process.sh" "$work/session"
  check
fi
