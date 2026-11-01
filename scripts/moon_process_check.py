#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.10"
# dependencies = ["numpy>=1.26", "tifffile>=2024.1", "imagecodecs>=2024.1"]
# ///
"""Scores a mosaic against a synthetic session's truth (ADR 0019, step 6).

    moon_process_check.py <session folder>

Compares <session>/mosaic.tif with <session>/truth.pgm (written by
MoonMosaicSynth: the whole Moon in the camera's orientation and scale,
centred) and fails unless the mosaic is in place, covers the Moon, and has no
misplaced tiles (which show as ghosted craters in 128-pixel blocks).
"""

import sys
from pathlib import Path

import numpy as np
import tifffile


def read_pgm(path: Path) -> np.ndarray:
    data = path.read_bytes()
    magic, size, _, pixels = data.split(b"\n", 3)
    assert magic == b"P5"
    w, h = map(int, size.split())
    return np.frombuffer(pixels, np.uint8).reshape(h, w).astype(np.float32)


def ncc(a: np.ndarray, b: np.ndarray) -> float:
    a, b = a - a.mean(), b - b.mean()
    return float((a * b).sum() / np.sqrt((a * a).sum() * (b * b).sum() + 1e-9))


def offset(a: np.ndarray, b: np.ndarray) -> tuple[int, int]:
    """Where a's content lies in b (whole pixels), by phase correlation."""
    fa, fb = np.fft.rfft2(a - a.mean()), np.fft.rfft2(b - b.mean())
    cross = fb * np.conj(fa)
    corr = np.fft.irfft2(cross / (np.abs(cross) + 1e-9), s=a.shape)
    y, x = np.unravel_index(np.argmax(corr), corr.shape)
    h, w = a.shape
    return (int(y - h if y > h / 2 else y), int(x - w if x > w / 2 else x))


def main() -> None:
    folder = Path(sys.argv[1])
    truth = read_pgm(folder / "truth.pgm")
    mosaic = tifffile.imread(folder / "mosaic.tif").astype(np.float32)
    covered = mosaic[..., -1] > 0 if mosaic.ndim == 3 else np.ones(mosaic.shape, bool)
    mosaic = mosaic[..., 0] if mosaic.ndim == 3 else mosaic
    if mosaic.shape != truth.shape:
        sys.exit(f"FAIL: mosaic {mosaic.shape}, truth {truth.shape}")

    dy, dx = offset(truth, mosaic)
    mosaic = np.roll(mosaic, (-dy, -dx), (0, 1))
    covered = np.roll(covered, (-dy, -dx), (0, 1))
    moon = truth > 20
    lit = moon & covered
    coverage = lit.sum() / moon.sum()
    overall = ncc(truth[lit], mosaic[lit])
    # Blocks wholly on the Moon with detail in them: a misplaced tile ghosts.
    b = 128
    scores = []
    for y in range(0, truth.shape[0] - b + 1, b):
        for x in range(0, truth.shape[1] - b + 1, b):
            t = truth[y : y + b, x : x + b]
            if lit[y : y + b, x : x + b].all() and t.std() > 8:
                scores.append(ncc(t, mosaic[y : y + b, x : x + b]))
    good = float(np.mean(np.array(scores) >= 0.85))

    print(
        f"offset ({dy}, {dx}) px, coverage {coverage:.3f}, correlation {overall:.3f}, "
        f"{good:.0%} of {len(scores)} detailed blocks ≥ 0.85 (worst {min(scores):.2f})"
    )
    failures = []
    if max(abs(dy), abs(dx)) > 8:
        failures.append("off centre")
    if coverage < 0.99:
        failures.append("gaps")
    if overall < 0.95:
        failures.append("poor match")
    if good < 0.95:
        failures.append("misplaced tiles")
    if failures:
        sys.exit("FAIL: " + ", ".join(failures))
    print("PASS")


if __name__ == "__main__":
    main()
