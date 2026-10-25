#!/usr/bin/env python3
"""Calibration (spec §10.1): compare detected activity with logged HealthKit workouts.

Runs `activity` on a COPY of the database with the workout override off, then for
every workout whose type maps to an activity label reports per-label recall (share
of the workout's minutes labelled correctly) and precision (share of minutes
labelled X that fall inside a workout of type X — a lower bound, since walks you
didn't log as workouts count against it). Server-side tool; not shipped to the phone.

    .venv/bin/python engine/tools/calibrate.py DB --days 60 [--tz America/New_York]
"""

from __future__ import annotations

import argparse
import json
import shutil
import sqlite3
import sys
import tempfile
import time
from collections import defaultdict
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

import fengshui_engine  # noqa: E402
from fengshui_engine import config as C  # noqa: E402
from fengshui_engine.minute import minute_id  # noqa: E402

TYPE_TO_LABEL = {"running": "running", "walking": "walking", "hiking": "walking", "cycling": "cycling",
                 "stair_climbing": "stairs", "stairs": "stairs"}


def calibrate(db: str, *, now: float, tz: str, days: int, source_like: str = "%") -> dict:
    """`source_like` (SQL LIKE) limits the reference workouts, e.g. '%Watch%' for ones the user
    started — auto-detected workouts from other apps are often not the activity they're named."""
    tmp = Path(tempfile.mkdtemp()) / "calib.sqlite"
    src = sqlite3.connect(db)
    dst = sqlite3.connect(tmp)
    src.backup(dst)          # consistent copy even if the source is in WAL mode
    src.close()
    dst.execute("DELETE FROM inferences")
    dst.execute("DELETE FROM engine_state WHERE key LIKE 'activity.%'")
    dst.commit()
    dst.close()
    old = C.ACTIVITY_FIRST_RUN_DAYS
    C.ACTIVITY_FIRST_RUN_DAYS = days
    try:
        fengshui_engine.run(str(tmp), now_ts=now, tz=tz, where="server", tasks=["activity"],
                            options={"workout_override": False})
    finally:
        C.ACTIVITY_FIRST_RUN_DAYS = old
    conn = sqlite3.connect(tmp)
    lo = minute_id(now - days * 86400)
    labels: dict[int, str] = {}
    for s, e, v in conn.execute("SELECT minute_start, minute_end, value_json FROM inferences WHERE kind='activity_bout' "
                                "AND superseded_by IS NULL AND minute_end > ?", (lo,)):
        lab = json.loads(v)["label"]
        for m in range(s, e):
            labels[m] = lab
    in_workout: dict[int, str] = {}
    n_workouts = defaultdict(int)
    for typ, s, e in conn.execute("SELECT value_text, start_ts, end_ts FROM processed_samples WHERE label='workout' "
                                  "AND deleted=0 AND end_ts > ? AND COALESCE(source_name, '') LIKE ?",
                                  (lo * 60, source_like)):
        lab = TYPE_TO_LABEL.get(typ or "")
        if not lab:
            continue
        n_workouts[lab] += 1
        for m in range(minute_id(s), minute_id(e)):
            in_workout[m] = lab
    out = {}
    for lab in sorted(set(TYPE_TO_LABEL.values())):
        w_min = [m for m, l in in_workout.items() if l == lab]
        d_min = [m for m, l in labels.items() if l == lab]
        hits = sum(1 for m in w_min if labels.get(m) == lab)
        out[lab] = {"workouts": n_workouts[lab], "workout_minutes": len(w_min),
                    "recall": round(hits / len(w_min), 3) if w_min else None,
                    "detected_minutes": len(d_min),
                    "precision_lower_bound": round(sum(1 for m in d_min if in_workout.get(m) == lab) / len(d_min), 3)
                    if d_min else None}
    conf = defaultdict(int)
    for m, l in in_workout.items():
        conf[(l, labels.get(m, "none"))] += 1
    out["_confusion_in_workouts"] = {f"{a}->{b}": n for (a, b), n in sorted(conf.items(), key=lambda x: -x[1])[:15]}
    conn.close()
    shutil.rmtree(tmp.parent, ignore_errors=True)
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("db")
    ap.add_argument("--days", type=int, default=60)
    ap.add_argument("--tz", default="America/New_York")
    ap.add_argument("--now", type=float, default=None)
    ap.add_argument("--source", default="%", help="SQL LIKE filter on workout source, e.g. %%Watch%%")
    a = ap.parse_args()
    now = a.now or sqlite3.connect(a.db).execute("SELECT MAX(end_ts) FROM processed_samples").fetchone()[0]
    print(json.dumps(calibrate(a.db, now=now, tz=a.tz, days=a.days, source_like=a.source), indent=1))


if __name__ == "__main__":
    t = time.time()
    main()
    print(f"({time.time() - t:.0f} s)", file=sys.stderr)
