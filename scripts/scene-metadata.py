#!/usr/bin/env python3
"""Prepare the owner's Moon images for the repo as simulator scenes (CC0).

docs/privacy.md's exception for the owner's own images: keep the metadata
(the stacking records are valued), but round every location to whole
degrees, drop altitude, and drop serial numbers and other unique IDs.

    scripts/scene-metadata.py OUT_DIR IMAGE [IMAGE ...]

Copies each image (and its `<image>.json` sidecar, location rounded the same
way) into OUT_DIR, edits the copy with exiftool, then re-reads it and checks:
no location finer than a whole degree, no serials, and none of the site's
coordinates (from the Moon Mosaic settings, compared without printing them)
left anywhere in the file, in any tag or in the raw bytes. Writes
OUT_DIR/metadata-review.md: every tag changed or removed, for review before
anything is committed. Location values before the change are never printed.
"""

import json
import re
import shutil
import subprocess
import sys
from pathlib import Path

SETTINGS = Path.home() / "Library/Application Support/MoonMosaic/settings.json"

# Tags to remove outright: serials, owner names, unique document IDs, altitude.
DROP = re.compile(
    r"(serial|uniqueid|unique_id|documentid|instanceid|ownername|owner|"
    r"bodyserial|lensserial|internalserial|cameraid|deviceid|udid|imei|"
    r"gpsaltitude|gpsaltituderef|altitude|gpsposition|gpsareainformation|"
    r"gpsdestlat|gpsdestlong|gpsdest|gpsprocessingmethod|gpshpositioningerror)",
    re.I,
)
# Tags holding a latitude or longitude, to round.
LATLON = re.compile(r"(latitude|longitude|^lat$|^lon$|^long$)", re.I)


def exif(path, *args):
    out = subprocess.run(["exiftool", *args, str(path)], capture_output=True, text=True, check=True)
    return out.stdout


def tags(path):
    """All tags, grouped by family-1 group, values as numbers where possible."""
    return json.loads(exif(path, "-j", "-a", "-G1", "-n", "-struct"))[0]


def site():
    try:
        d = json.loads(SETTINGS.read_text())
        lat, lon = float(d.get("latitude", 0)), float(d.get("longitude", 0))
        return (lat, lon) if (lat, lon) != (0, 0) else None
    except Exception:
        return None


def site_patterns(s):
    """Text forms of the site's coordinates to look for (2+ decimals)."""
    if not s:
        return []
    out = []
    for v in s:
        for digits in (2, 3, 4):
            out.append(f"{abs(v):.{digits}f}")
        # Degrees and minutes, as GPS strings often have them.
        d = int(abs(v))
        m = (abs(v) - d) * 60
        out.append(f"{d} deg {int(m)}'")
        out.append(f"{d},{m:.2f}")
    return [p for p in out if not p.endswith(".00")]


def plan_changes(t):
    """(remove, round) lists of tag keys like 'GPS:GPSLatitude'."""
    remove, rounding = [], []
    for key, value in t.items():
        if key == "SourceFile" or ":" not in key:
            continue
        group, name = key.split(":", 1)
        if group in ("System", "File", "Composite", "ExifTool"):
            continue
        if name.endswith("Ref") and LATLON.search(name):
            continue  # N/S, E/W: the sign of the rounded value
        if DROP.search(name):
            remove.append(key)
        elif LATLON.search(name) and isinstance(value, (int, float)):
            rounding.append((key, round(float(value))))
        elif LATLON.search(name):
            # A text location (e.g. "37 deg 20' 10.00\" N"): remove it; the
            # numeric GPS tags carry the rounded value.
            remove.append(key)
    return remove, rounding


def round_sidecar(src, dst):
    d = json.loads(src.read_text())
    for k in ("latitude", "longitude"):
        if isinstance(d.get(k), (int, float)):
            d[k] = round(d[k])
    d.pop("altitude", None)
    d.setdefault("licence", "CC0-1.0")
    dst.write_text(json.dumps(d, indent=2, sort_keys=True) + "\n")


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        sys.exit(2)
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    s = site()
    patterns = site_patterns(s)
    review = ["# Scene metadata review", "",
              "Location values before the change are not shown. Check this list before committing.", ""]
    problems = 0
    for name in sys.argv[2:]:
        src = Path(name)
        dst = out / src.name
        shutil.copy2(src, dst)
        side = Path(str(src) + ".json")
        if side.exists():
            round_sidecar(side, Path(str(dst) + ".json"))
        before = tags(dst)
        remove, rounding = plan_changes(before)
        args = ["-overwrite_original", "-n"]
        args += [f"-{k}=" for k in remove]
        args += [f"-{k}={v}" for k, v in rounding]
        # GPS refs stay; the numeric values are now whole degrees.
        if remove or rounding:
            exif(dst, *args)
        after = tags(dst)
        review.append(f"## {src.name}")
        review.append("")
        for k in remove:
            shown = "(location)" if LATLON.search(k) or "GPS" in k else repr(before.get(k))[:60]
            review.append(f"- removed `{k}`: {shown}")
        for k, v in rounding:
            review.append(f"- rounded `{k}` to {v}")
        # Checks on the result.
        left = [k for k in after if ":" in k and DROP.search(k.split(":", 1)[1])
                and k.split(":", 1)[0] not in ("System", "File", "Composite", "ExifTool")]
        fine = [k for k, v in after.items() if ":" in k and LATLON.search(k.split(":", 1)[1])
                and isinstance(v, (int, float)) and abs(v - round(v)) > 1e-9]
        raw = dst.read_bytes().decode("latin-1")
        leaked = [p for p in patterns if p in raw]
        for k in left:
            review.append(f"- **STILL PRESENT** `{k}`")
        for k in fine:
            review.append(f"- **NOT ROUNDED** `{k}`")
        if leaked:
            review.append(f"- **SITE COORDINATES STILL IN THE FILE** ({len(leaked)} matches; the bytes need editing by hand)")
        problems += len(left) + len(fine) + (1 if leaked else 0)
        kept = len([k for k in after if ":" in k and k.split(":", 1)[0] not in ("System", "File", "Composite", "ExifTool")])
        review.append(f"- kept {kept} other tags")
        review.append("")
        print(f"{src.name}: removed {len(remove)}, rounded {len(rounding)}"
              + ("" if not (left or fine or leaked) else "  ** needs attention **"))
    if not s:
        review.append("Note: no site in the Moon Mosaic settings, so the raw-bytes check for the site's coordinates was skipped.")
    (out / "metadata-review.md").write_text("\n".join(review) + "\n")
    print(f"Review: {out / 'metadata-review.md'}" + (f"  ({problems} problems)" if problems else ""))
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
