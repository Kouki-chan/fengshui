"""Writes the shared raw-codec test vectors to fixtures/raw/.

- vectors.json:   source of truth (quantized samples per vector)
- <name>.fsr1:    uncompressed bytes from the Python packer (Swift must match byte-for-byte)
Swift tests add swift/<name>.bin (Apple COMPRESSION_ZLIB output) which Python must decode.

Run: .venv/bin/python engine/tests/make_raw_vectors.py
"""

import json
import math
import random
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))

from fengshui_engine import raw  # noqa: E402

OUT = ROOT / "fixtures" / "raw"


def walking_accel(seed: int, n: int, rate: float) -> list[tuple[float, ...]]:
    rnd = random.Random(seed)
    out = []
    for i in range(n):
        t = i / rate
        step = math.sin(2 * math.pi * 1.8 * t)
        out.append((0.25 * step + rnd.gauss(0, 0.02),
                    0.10 * math.sin(2 * math.pi * 0.9 * t) + rnd.gauss(0, 0.02),
                    -1.0 + 0.35 * step + rnd.gauss(0, 0.03)))
    return out


def vectors() -> list[dict]:
    base = 1792843200.0  # 2026-10-24T12:00:00Z, minute aligned
    v = []

    def add(name, sensor, rate, samples_int, gaps=()):
        v.append({"name": name, "sensor": sensor, "start_ts": base, "rate_hz": rate,
                  "gaps": [list(g) for g in gaps], "samples": [list(s) for s in samples_int]})

    add("accel_walk_50hz", "accel", 50.0, raw.quantize("accel", walking_accel(1, 3000, 50.0)))
    add("accel_gap", "accel", 50.0, raw.quantize("accel", walking_accel(2, 2500, 50.0)),
        gaps=[(1200, 500)])
    # Deltas that overflow int16 and must wrap.
    add("accel_wrap", "accel", 50.0, [(32767, -32768, 0), (-32768, 32767, 1), (32767, 0, -32768),
                                     (0, 0, 0), (-32768, -32768, 32767)])
    add("accel_single", "accel", 50.0, [(1, -2048, 3)])
    add("accel_empty", "accel", 50.0, [])
    rnd = random.Random(3)
    add("gyro_snapshot_25hz", "gyro", 25.0,
        raw.quantize("gyro", [(rnd.gauss(0, .5), rnd.gauss(0, .5), rnd.gauss(0, .5)) for _ in range(125)]))
    add("baro_25hz", "baro", 25.0,
        raw.quantize("baro", [(101.325 - 0.0004 * i + rnd.gauss(0, 0.0005),) for i in range(125)]))
    add("compass_25hz", "compass", 25.0,
        raw.quantize("compass", [((350 + 0.4 * i) % 360,) for i in range(125)]))
    add("hr_session_02hz", "hr_session", 0.2, raw.quantize("hr_session", [(72 + i * 0.5,) for i in range(12)]))
    return v


def to_chunk(d: dict) -> raw.RawChunk:
    return raw.RawChunk(sensor=d["sensor"], start_ts=d["start_ts"], rate_hz=d["rate_hz"],
                        samples=[tuple(s) for s in d["samples"]], gaps=[tuple(g) for g in d["gaps"]])


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    vs = vectors()
    (OUT / "vectors.json").write_text(json.dumps(vs, separators=(",", ":")))
    (OUT / "py").mkdir(exist_ok=True)
    for d in vs:
        (OUT / f"{d['name']}.fsr1").write_bytes(raw.pack(to_chunk(d)))
        # Python-compressed copy so Swift proves it can decode zlib raw DEFLATE too.
        (OUT / "py" / f"{d['name']}.bin").write_bytes(raw.encode(to_chunk(d)))
    print(f"wrote {len(vs)} vectors to {OUT}")


if __name__ == "__main__":
    main()
