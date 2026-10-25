"""Nights from HealthKit sleep_analysis (spec §10.2 step 1), shared by `activity`
(main-sleep override) and `wind_down`.

Asleep samples (asleep_*) are unioned across sources, gaps ≤ 45 min merged into
episodes. The main sleep of a night is the longest episode ≥ 3 h and belongs to the
local date of its wake time; shorter episodes are naps.
"""

from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import date, datetime
from zoneinfo import ZoneInfo

from . import config as C
from .hk_labels import SLEEP_ASLEEP


@dataclass
class Night:
    wake_date: date        # local date of the wake time
    onset: float
    wake: float
    asleep_min: float
    latency_min: float | None
    in_bed_start: float | None
    stage_min: dict


def _union(intervals: list[tuple[float, float]]) -> list[list[float]]:
    out: list[list[float]] = []
    for s, e in sorted(intervals):
        if out and s <= out[-1][1]:
            out[-1][1] = max(out[-1][1], e)
        else:
            out.append([s, e])
    return out


def nights(conn: sqlite3.Connection, tz: str, start_ts: float, end_ts: float) -> list[Night]:
    zone = ZoneInfo(tz)
    rows = conn.execute(
        "SELECT value_text, start_ts, end_ts FROM processed_samples WHERE label='sleep_analysis' AND deleted=0 "
        "AND end_ts >= ? AND start_ts <= ? ORDER BY start_ts", (start_ts - 86400, end_ts)).fetchall()
    asleep = [(s, e) for t, s, e in rows if t in SLEEP_ASLEEP and e > s]
    in_bed = [(s, e) for t, s, e in rows if t == "in_bed" and e > s]
    stages: dict[str, list[tuple[float, float]]] = {}
    for t, s, e in rows:
        if t in SLEEP_ASLEEP or t == "awake":
            stages.setdefault(t, []).append((s, e))

    episodes: list[list] = []
    for s, e in _union(asleep):
        if episodes and s - episodes[-1][1] <= C.SLEEP_MERGE_GAP_MIN * 60:
            episodes[-1][1] = e
            episodes[-1][2].append((s, e))
        else:
            episodes.append([s, e, [(s, e)]])

    best: dict[date, Night] = {}
    for s, e, parts in episodes:
        if e - s < C.MAIN_SLEEP_MIN_H * 3600:
            continue
        wd = datetime.fromtimestamp(e, zone).date()
        asleep_min = sum(b - a for a, b in parts) / 60
        bed = [b for b in in_bed if b[0] <= s <= b[1]]
        bed_start = min(b[0] for b in bed) if bed else None
        stage_min = {k: round(sum(max(0.0, min(b, e) - max(a, s)) for a, b in _union(v)) / 60, 1)
                     for k, v in stages.items()}
        n = Night(wd, s, e, round(asleep_min, 1),
                  round((s - bed_start) / 60, 1) if bed_start is not None else None, bed_start, stage_min)
        if wd not in best or (best[wd].wake - best[wd].onset) < (e - s):
            best[wd] = n
    return [best[d] for d in sorted(best) if start_ts <= best[d].wake <= end_ts]
