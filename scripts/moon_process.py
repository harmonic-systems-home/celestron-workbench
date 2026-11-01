#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy>=1.26", "tifffile>=2024.1", "imagecodecs>=2024.1"]
# ///
"""Turns a Moon mosaic session into one image (ADR 0019, step 6).

    moon_process.py <session folder> [--quick] [--pss PATH] [--hugin DIR]

1. Stack each captured tile's SER: Planetary System Stacker in Surface mode,
   or, with --quick or without PSS, a lucky-imaging stack here (the sharpest
   quarter of the frames, aligned by phase correlation and averaged).
2. Stitch with Hugin's command-line tools, each tile seeded where the session
   log says it was (encoders and calibration, in the camera's own pixels);
   cpfind finds control points only between tiles that overlap there, and
   autooptimiser refines positions only. The mosaic is in the camera's
   orientation and scale, centred on the Moon.
3. Write <session>/mosaic.tif, 16 bits per channel. Work files go in
   <session>/processing/; stacked tiles there are reused on a second run.

Reads session.ndjson (written by the app): the last plan line, and for each
tile the last line about it.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import shutil
import subprocess
import sys
from pathlib import Path

import numpy as np
import tifffile

HUGIN_DEFAULT = "/Applications/Hugin/tools_mac"
PSS_DEFAULT = "~/venvs/pss/bin/PlanetarySystemStacker"


# Session log ----------------------------------------------------------------


def load_session(folder: Path) -> tuple[dict, list[dict]]:
    """The last plan and the captured tiles (the last line about each)."""
    plan = None
    latest: dict[int, dict] = {}
    with open(folder / "session.ndjson") as f:
        for line in f:
            if not line.strip():
                continue
            r = json.loads(line)
            if r.get("type") == "plan":
                plan = r
                latest = {}
            elif r.get("type") == "tile":
                latest[r["id"]] = r
    if plan is None:
        sys.exit(f"No plan in {folder / 'session.ndjson'}.")
    planned = {t["id"]: t for t in plan["tiles"]}
    tiles = []
    for tid, r in sorted(latest.items()):
        if r.get("state") != "done":
            continue
        center = r.get("measured") or planned[tid]["center"]
        tiles.append({"id": tid, "file": r["file"], "center": (center["x"], center["y"])})
    return plan, tiles


# SER and stacking -------------------------------------------------------------


def read_ser(path: Path) -> tuple[np.ndarray, int]:
    """All frames (n, height, width) and the SER colour ID."""
    with open(path, "rb") as f:
        header = f.read(178)
        color_id, little, width, height, depth, count = np.frombuffer(
            header[18:42], dtype="<i4"
        )
        dtype = np.uint8 if depth <= 8 else ("<u2" if little else ">u2")
        frames = np.fromfile(f, dtype=dtype, count=count * width * height)
    return frames.reshape(count, height, width), int(color_id)


def luminance(raw: np.ndarray, color_id: int) -> np.ndarray:
    """Float image; a Bayer frame smoothed with a 3×3 kernel, which mixes each
    pixel's colours into a luminance at full resolution."""
    img = raw.astype(np.float32)
    if color_id < 8:
        return img
    k = np.array([1, 2, 1], dtype=np.float32) / 4
    p = np.pad(img, 1, mode="edge")
    rows = k[0] * p[:-2] + k[1] * p[1:-1] + k[2] * p[2:]
    return k[0] * rows[:, :-2] + k[1] * rows[:, 1:-1] + k[2] * rows[:, 2:]


def sharpness(img: np.ndarray) -> float:
    """Mean squared gradient over the lit part, as the app's focus measure."""
    gx = img[1:-1, 2:] - img[1:-1, :-2]
    gy = img[2:, 1:-1] - img[:-2, 1:-1]
    lit = img[1:-1, 1:-1] > 0.1 * img.max()
    return float(((gx**2 + gy**2)[lit]).mean()) if lit.any() else 0.0


def shift_between(a: np.ndarray, b: np.ndarray) -> tuple[float, float]:
    """(dy, dx): where a's content lies in b, by phase correlation with a Hann
    window, to a fraction of a pixel. The finest detail (sensor noise, which
    phase correlation would otherwise weigh as much as the craters) is
    damped first."""
    h, w = a.shape
    win = np.outer(np.hanning(h), np.hanning(w)).astype(np.float32)
    fa = np.fft.rfft2((a - a.mean()) * win)
    fb = np.fft.rfft2((b - b.mean()) * win)
    cross = fb * np.conj(fa)
    ky = np.fft.fftfreq(h)[:, None]
    kx = np.fft.rfftfreq(w)[None, :]
    smooth = np.exp(-2 * (np.pi * 2.0) ** 2 * (ky**2 + kx**2))  # a 2-pixel Gaussian
    corr = np.fft.irfft2(cross / (np.abs(cross) + 1e-9) * smooth, s=a.shape)
    y, x = np.unravel_index(np.argmax(corr), corr.shape)

    def refine(c_minus: float, c0: float, c_plus: float) -> float:
        d = c_minus - 2 * c0 + c_plus
        return 0.5 * (c_minus - c_plus) / d if d < 0 else 0.0

    dy = y + refine(corr[y - 1, x], corr[y, x], corr[(y + 1) % h, x])
    dx = x + refine(corr[y, x - 1], corr[y, x], corr[y, (x + 1) % w])
    if dy > h / 2:
        dy -= h
    if dx > w / 2:
        dx -= w
    return float(dy), float(dx)


def shifted(img: np.ndarray, dy: float, dx: float) -> np.ndarray:
    """img moved by (dy, dx), by the Fourier shift theorem, with the edges
    padded by reflection so nothing wraps round. Same size as img."""
    m = int(math.ceil(max(abs(dy), abs(dx)))) + 2
    p = np.pad(img, m, mode="reflect")
    h, w = p.shape
    ky = np.fft.fftfreq(h)[:, None]
    kx = np.fft.rfftfreq(w)[None, :]
    f = np.fft.rfft2(p) * np.exp(-2j * np.pi * (ky * dy + kx * dx))
    return np.fft.irfft2(f, s=p.shape)[m:-m, m:-m].astype(np.float32)


def lit_fraction(img: np.ndarray, top: float) -> float:
    """How much of the frame is Moon: 4×-binned (to quiet the noise) pixels
    above 6% of full scale."""
    h, w = (img.shape[0] // 4) * 4, (img.shape[1] // 4) * 4
    binned = img[:h, :w].reshape(h // 4, 4, w // 4, 4).mean(axis=(1, 3))
    return float((binned > 0.06 * top).mean())


def quick_stack(ser: Path) -> np.ndarray:
    """The sharpest quarter of the frames (at least 5), aligned to the one
    nearest the video's middle (so the tile stays where the log put it) and
    averaged; a frame whose shift is out of line with the rest (a mismatch)
    is left out. A tile with almost no Moon in it (nothing to align on) is
    averaged as it is. The frame's size, 16-bit."""
    raw, color_id = read_ser(ser)
    top = 255.0 if raw.dtype == np.uint8 else 65535.0
    frames = [luminance(f, color_id) for f in raw]
    scores = np.array([sharpness(f) for f in frames])
    keep = max(5, round(0.25 * len(frames)))
    best = sorted(np.argsort(scores)[::-1][:keep])
    ref = min(best, key=lambda i: abs(i - (len(frames) - 1) / 2))
    if lit_fraction(frames[ref], top) < 0.02:
        shifts = {i: np.zeros(2) for i in best}
    else:
        shifts = {i: np.array(shift_between(frames[ref], frames[i])) for i in best}
    middle = np.median(np.array(list(shifts.values())), axis=0)
    limit = max(3.0, 0.02 * min(frames[ref].shape))
    kept = [i for i in best if np.hypot(*(shifts[i] - middle)) <= limit] or [ref]
    total = np.zeros_like(frames[ref])
    for i in kept:
        total += shifted(frames[i], *(-shifts[i]))
    mean = total / len(kept)
    return np.clip(mean / top * 65535, 0, 65535).astype(np.uint16)


def pss_stack(pss: str, ser: Path, out: Path) -> bool:
    """Planetary System Stacker in Surface mode; it writes <stem>_pss.tiff,
    or nothing (and still exits 0) when it finds too little to align on."""
    result = ser.with_name(ser.stem + "_pss.tiff")
    subprocess.run(
        [pss, "-m", "Surface", "--out_format", "tiff", "-s", "25", str(ser)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
    )
    if not result.exists():
        return False
    shutil.move(result, out)
    return True


# Stitching --------------------------------------------------------------------


def hugin(tools: str, name: str, *args: str) -> None:
    subprocess.run(
        [os.path.join(tools, name), *args],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    )


def stitch(
    tools: str, work: Path, stacked: list[tuple[dict, Path]], plan: dict, out: Path
) -> tuple[int, list[int]]:
    """Seeds, control points, positions, remap and blend; returns the number
    of control points kept and the tiles left at their seeds."""
    scale = plan["calibration"]["arcsecPerPixel"] / 3600  # degrees per pixel
    base = work / "seed.pto"
    hugin(tools, "pto_gen", "-p", "0", "-f", "1", "-o", str(base), *(str(p) for _, p in stacked))
    # pto_gen sorts the images by name: take its order from the project.
    by_stem = {p.stem: tile for tile, p in stacked}
    tiles = [by_stem[Path(name).stem] for name in image_names(base)]
    sets = [f"v={plan['frameWidth'] * scale:.8f}"]  # all the frame's size: one lens
    for i, tile in enumerate(tiles):
        cx, cy = tile["center"]
        sets += [f"y{i}={cx * scale:.8f}", f"p{i}={-cy * scale:.8f}", f"r{i}=0"]
    seeded = work / "seeded.pto"
    hugin(tools, "pto_var", "--set=" + ",".join(sets), "-o", str(seeded), str(base))
    # Positions only, the lens fixed; the tile nearest the Moon's centre (the
    # most detail) holds the frame.
    a = min(range(len(tiles)), key=lambda i: math.hypot(*tiles[i]["center"]))
    hugin(tools, "pto_var", f"--opt=y,p,r,!y{a},!p{a},!r{a}", "-o", str(seeded), str(seeded))
    side = int(2.2 * plan["moonRadiusPixels"]) & ~1
    hugin(
        tools, "pano_modify", "-p", "0", f"--fov={side * scale:.8f}",
        f"--canvas={side}x{side}", "--ldr-compression=LZW", "-o", str(seeded), str(seeded),
    )
    cps = work / "cp.pto"
    hugin(tools, "cpfind", "--prealigned", "-o", str(cps), str(seeded))
    # The Moon's texture repeats enough to fool the matcher now and then (a
    # pair matched a whole tile off); the log's positions are good to a few
    # pixels, so a match far from where they put it is dropped.
    near = work / "near.pto"
    drop_far_matches(cps, near, scale, limit=max(30.0, 0.08 * plan["frameHeight"]))
    clean = work / "clean.pto"
    hugin(tools, "cpclean", "-o", str(clean), str(near))
    final = work / "final.pto"
    hugin(tools, "autooptimiser", "-n", "-o", str(final), str(clean))
    kept = sum(1 for line in open(final) if line.startswith("c "))
    # A tile the optimiser moved more than half a frame from where the log put
    # it was matched wrongly (or its group had nothing to hold it): reset.
    reset = []
    for i, (tile, (y, p, r)) in enumerate(zip(tiles, positions(final))):
        cx, cy = tile["center"]
        moved = math.hypot(y / scale - cx, -p / scale - cy)
        if moved > 0.5 * plan["frameHeight"] or abs(r) > 5:
            reset.append(tile["id"])
            sets = f"y{i}={cx * scale:.8f},p{i}={-cy * scale:.8f},r{i}=0"
            hugin(tools, "pto_var", "--set=" + sets, "-o", str(final), str(final))
    for old in work.glob("remap*.tif"):
        old.unlink()
    hugin(tools, "nona", "-m", "TIFF_m", "-z", "LZW", "-o", str(work / "remap"), str(final))
    hugin(
        tools, "enblend", "--compression=LZW", "-o", str(out),
        *sorted(str(p) for p in work.glob("remap*.tif")),
    )
    return kept, reset


def pad_to_frame(paths: list[Path], height: int, width: int) -> None:
    """Puts each stacked tile smaller than the frame (PSS trims each to what
    all its frames share) in the middle of a frame-sized canvas, the border
    transparent, so all share one lens in Hugin and keep their overlaps."""
    for p in paths:
        img = tifffile.imread(p)
        h, w = img.shape[:2]
        if (h, w) == (height, width):
            continue
        channels = 1 if img.ndim == 2 else img.shape[2]
        out = np.zeros((height, width, channels + 1), dtype=np.uint16)
        y0, x0 = (height - h) // 2, (width - w) // 2
        out[y0 : y0 + h, x0 : x0 + w, :channels] = img.reshape(h, w, channels)
        out[y0 : y0 + h, x0 : x0 + w, channels] = 65535
        tifffile.imwrite(
            p, out, photometric="rgb" if channels == 3 else "minisblack",
            extrasamples=["unassalpha"], compression="lzw",
        )


def drop_far_matches(pto: Path, out: Path, scale: float, limit: float) -> None:
    """Copies the project without control points that disagree with the
    images' seeded positions by more than `limit` pixels."""
    images = []  # (x, y) of each image's top-left corner on the canvas
    lines = open(pto).read().splitlines()
    for line in lines:
        if line.startswith("i "):
            f = {t[0]: t[1:] for t in line.split()[1:] if t[:1] in "ywhp"}
            images.append(
                (float(f["y"]) / scale - int(f["w"]) / 2, -float(f["p"]) / scale - int(f["h"]) / 2)
            )
    kept = []
    for line in lines:
        if line.startswith("c "):
            f = {t[0]: t[1:] for t in line.split()[1:]}
            a, b = images[int(f["n"])], images[int(f["N"])]
            dx = (a[0] + float(f["x"])) - (b[0] + float(f["X"]))
            dy = (a[1] + float(f["y"])) - (b[1] + float(f["Y"]))
            if math.hypot(dx, dy) > limit:
                continue
        kept.append(line)
    out.write_text("\n".join(kept) + "\n")


def image_names(pto: Path) -> list[str]:
    """The project's image files, in its order."""
    names = []
    for line in open(pto):
        if line.startswith("i "):
            names.append(line.split(' n"', 1)[1].rsplit('"', 1)[0])
    return names


def positions(pto: Path) -> list[tuple[float, float, float]]:
    """Each image's yaw, pitch and roll (degrees), in order."""
    out = []
    for line in open(pto):
        if line.startswith("i "):
            fields = {f[0]: f[1:] for f in line.split() if f[:1] in "ypr" and len(f) > 1}
            out.append(tuple(float(fields[k]) for k in "ypr"))
    return out


# Main -------------------------------------------------------------------------


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("session", type=Path)
    ap.add_argument("--quick", action="store_true", help="stack here, without PSS")
    ap.add_argument("--pss", default=os.environ.get("PSS", PSS_DEFAULT))
    ap.add_argument("--hugin", default=os.environ.get("HUGIN_TOOLS", HUGIN_DEFAULT))
    args = ap.parse_args()

    folder = args.session.expanduser().resolve()
    plan, tiles = load_session(folder)
    if not tiles:
        sys.exit("No captured tiles in the session log.")
    if not os.path.exists(os.path.join(args.hugin, "nona")):
        sys.exit(
            f"Hugin's tools aren't in {args.hugin} (brew install --cask hugin, "
            "or give --hugin DIR)."
        )
    pss = os.path.expanduser(args.pss)
    use_pss = not args.quick and os.access(pss, os.X_OK)
    work = folder / "processing"
    (work / "stacked").mkdir(parents=True, exist_ok=True)

    how = "Planetary System Stacker" if use_pss else "the quick stack"
    print(f"{len(tiles)} tiles of {len(plan['tiles'])} planned; stacking with {how}.")
    stacked = []
    quick = []  # tiles PSS couldn't align (mostly sky), stacked here instead
    for n, tile in enumerate(tiles, 1):
        ser = folder / tile["file"]
        out = work / "stacked" / (Path(tile["file"]).stem + ".tif")
        if not out.exists() and not (use_pss and pss_stack(pss, ser, out)):
            if use_pss:
                quick.append(tile["id"])
            tifffile.imwrite(out, quick_stack(ser), compression="lzw")
        stacked.append((tile, out))
        print(f"\r  stacked {n}/{len(tiles)}", end="", flush=True)
    print()
    if quick:
        ids = ", ".join(str(i) for i in quick)
        print(f"  PSS found too little to align on in tiles {ids}; quick-stacked those.")

    pad_to_frame([p for _, p in stacked], plan["frameHeight"], plan["frameWidth"])
    print("Stitching with Hugin (positions from the session log).")
    mosaic = folder / "mosaic.tif"
    try:
        kept, reset = stitch(args.hugin, work, stacked, plan, mosaic)
    except subprocess.CalledProcessError as e:
        tool = Path(e.cmd[0]).name
        detail = (e.stderr or b"").decode(errors="replace").strip().splitlines()[-3:]
        sys.exit(f"{tool} failed: " + " / ".join(detail))
    print(f"  {kept} control points between overlapping tiles.")
    if reset:
        ids = ", ".join(str(i) for i in sorted(reset))
        print(f"  Placed from the log alone (no reliable match): tiles {ids}.")
    print(f"Wrote {mosaic}")


if __name__ == "__main__":
    main()
