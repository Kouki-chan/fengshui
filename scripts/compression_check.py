#!/usr/bin/env python3
"""Compression ratio of the fsr1 codec on real watch recordings (local only, spec §7.3).

Reads Sensor Logger CSV exports (e.g. ~/Desktop/HealthExport/*.zip), resamples the
watch accelerometer to 50 Hz, encodes one chunk per minute and prints the ratio.
Nothing is written to the repo; only the ratio is reported.

    .venv/bin/python scripts/compression_check.py ~/Desktop/HealthExport/"36 min data-…zip"
"""

from __future__ import annotations

import csv
import io
import sys
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))
from fengshui_engine import raw  # noqa: E402
from fengshui_engine.minute import minute_id  # noqa: E402


def accel_rows(zp: Path):
    with zipfile.ZipFile(zp) as z:
        name = next(n for n in z.namelist() if n.endswith("WatchAccelerometerUncalibrated.csv"))
        with z.open(name) as fh:
            for r in csv.DictReader(io.TextIOWrapper(fh, "utf-8")):
                yield int(r["time"]) / 1e9, (float(r["x"]), float(r["y"]), float(r["z"]))


def main(paths: list[str]) -> None:
    for p in map(Path, paths):
        rows = sorted(accel_rows(p))
        # Resample to 50 Hz by picking the nearest sample per 20 ms slot.
        by_minute: dict[int, list] = {}
        last_slot = None
        for ts, v in rows:
            slot = round(ts * 50)
            if slot == last_slot:
                continue
            last_slot = slot
            by_minute.setdefault(minute_id(slot / 50), []).append((slot / 50, v))
        f32 = packed = comp = n = 0
        for mid, samples in sorted(by_minute.items()):
            q = raw.quantize("accel", [v for _, v in samples])
            c = raw.RawChunk("accel", samples[0][0], 50.0, q)
            f32 += len(q) * 12
            packed += len(raw.pack(c))
            comp += len(raw.encode(c))
            n += len(q)
        print(f"{p.name}: {len(by_minute)} minutes, {n} samples at 50 Hz → "
              f"ratio vs float32 {f32 / comp:.2f}, vs int16 {packed / comp:.2f}, "
              f"{comp / max(len(by_minute), 1) / 1024:.1f} KiB/min")


if __name__ == "__main__":
    main(sys.argv[1:])
