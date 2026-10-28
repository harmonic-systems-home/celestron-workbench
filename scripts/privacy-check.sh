#!/usr/bin/env bash
# Scan files for private data that must not reach the public repo.
# Usage: scripts/privacy-check.sh [file...]   (default: all tracked files)
# Allow a deliberate match by adding "privacy-check: allow" on the same line.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

if [ "$#" -gt 0 ]; then
  files=("$@")
else
  files=()
  while IFS= read -r f; do files+=("$f"); done < <(git ls-files)
fi

status=0
for f in "${files[@]}"; do
  [ -f "$f" ] || continue
  case "$f" in
    scripts/privacy-check.sh) continue ;;
  esac

  # Images: block embedded GPS/location metadata when exiftool is available.
  case "$(printf '%s' "$f" | tr '[:upper:]' '[:lower:]')" in
    *.jpg|*.jpeg|*.heic|*.png|*.tif|*.tiff|*.dng|*.mov|*.mp4)
      if command -v exiftool >/dev/null 2>&1; then
        if exiftool -q -q -gps:all -location:all "$f" | grep -q .; then
          echo "$f: image contains GPS/location metadata (strip with: exiftool -all= \"$f\")"
          status=1
        fi
      else
        echo "$f: warning: exiftool not installed; image metadata not checked" >&2
      fi
      continue ;;
  esac

  # Skip other binary files.
  if ! grep -Iq . "$f" 2>/dev/null; then continue; fi

  perl -ne '
    next if /privacy-check: allow/;
    my @hits;
    push @hits, "coordinate"       if /\b(lat|latitude|lon|lng|long|longitude|elevation|SITELAT|SITELONG|SITEELEV|OBSGEO-[BLHXYZ])\b["\x27]?\s*[:=]\s*["\x27]?[-+]?\d{1,3}\.\d{3,}/i;
    push @hits, "MAC address"      if /\b(?:[0-9A-Fa-f]{2}[:-]){5}[0-9A-Fa-f]{2}\b/;
    push @hits, "private IP"       if /\b(?:10\.\d{1,3}|192\.168|172\.(?:1[6-9]|2\d|3[01]))\.\d{1,3}\.\d{1,3}\b/;
    push @hits, "Apple Team ID"    if /\bDEVELOPMENT_TEAM\s*=\s*"?[A-Z0-9]{10}\b/;
    push @hits, "device UDID"      if /\b[0-9A-Fa-f]{8}-[0-9A-Fa-f]{16}\b/;
    push @hits, "Wi-Fi SSID"       if /\b(SSID|wifi_?name)\b["\x27]?\s*[:=]\s*\S/i;
    push @hits, "serial number"    if /\bserial(?:_?number|no)?\b["\x27]?\s*[:=]\s*["\x27]?[A-Z0-9]{6,}/i;
    push @hits, "personal email"   if /[A-Za-z0-9._%+-]+@(?:gmail|googlemail|icloud|me|mac|yahoo|outlook|hotmail|aol)\.com\b/i;
    if (@hits) { print "$ARGV:$.: ", join(", ", @hits), "\n"; $found = 1 }
    END { exit($found ? 1 : 0) }
  ' "$f" || status=1
done

if [ "$status" -ne 0 ]; then
  echo
  echo "privacy-check: possible private data found (see docs/privacy.md)."
  echo "If a match is intentional, add 'privacy-check: allow' on that line."
fi
exit "$status"
