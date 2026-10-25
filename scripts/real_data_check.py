#!/usr/bin/env python3
"""Real-data check (spec §14.1): run the engine over the owner's imported Health export.

Works on a copy of ~/Desktop/HealthExport/fengshui_health.sqlite and writes a
LOCAL-ONLY report to ~/Desktop/HealthExport/engine_check.md (never committed):
share of minutes labelled `unknown`, detected bouts vs logged workouts (calibrate.py),
wind-down plans for the last 30 nights vs actual sleep, and any errors. It prints only
pass/fail and percentages, which may go into docs/PROGRESS.md.

    .venv/bin/python scripts/real_data_check.py [--days 30] [--tz America/New_York]
"""

from __future__ import annotations

import argparse
import json
import sqlite3
import statistics
import sys
import tempfile
import time
import traceback
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[1]
sys.path[:0] = [str(ROOT / "engine"), str(ROOT / "engine" / "tools")]

import calibrate  # noqa: E402
import fengshui_engine  # noqa: E402
from fengshui_engine import config as C  # noqa: E402
from fengshui_engine import sleep  # noqa: E402
from fengshui_engine.minute import minute_id  # noqa: E402
from fengshui_engine.wind_down import clock_min, parse_hhmm  # noqa: E402

HE = Path.home() / "Desktop" / "HealthExport"


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--db", default=str(HE / "fengshui_health.sqlite"))
    ap.add_argument("--days", type=int, default=30)
    ap.add_argument("--tz", default="America/New_York")
    a = ap.parse_args()
    zone = ZoneInfo(a.tz)
    t_start = time.time()
    errors: list[str] = []
    work = Path(tempfile.mkdtemp()) / "check.sqlite"
    src = sqlite3.connect(a.db)
    dst = sqlite3.connect(work)
    src.backup(dst)
    src.close()
    dst.close()
    conn = sqlite3.connect(work)
    now = conn.execute("SELECT MAX(end_ts) FROM processed_samples WHERE label='heart_rate'").fetchone()[0]
    report = ["# Engine check on real Health data (LOCAL ONLY — do not commit)", "",
              f"- Run {datetime.now():%Y-%m-%d %H:%M}, database copy of `{a.db}`",
              f"- Analysis end: {datetime.fromtimestamp(now, zone):%Y-%m-%d %H:%M}, window {a.days} days", ""]
    summary = {}

    # 1. Activity over the window (workout override on, as the app runs it).
    try:
        old = C.ACTIVITY_FIRST_RUN_DAYS
        C.ACTIVITY_FIRST_RUN_DAYS = a.days
        t = time.time()
        s = fengshui_engine.run(str(work), now_ts=now, tz=a.tz, where="server", tasks=["activity"])
        C.ACTIVITY_FIRST_RUN_DAYS = old
        lo = minute_id(now - a.days * 86400)
        per: dict[str, int] = {}
        for st, e, v in conn.execute("SELECT minute_start, minute_end, value_json FROM inferences WHERE "
                                     "kind='activity_bout' AND superseded_by IS NULL AND minute_end > ?", (lo,)):
            lab = json.loads(v)["label"]
            per[lab] = per.get(lab, 0) + (e - max(st, lo))
        total = sum(per.values()) or 1
        unknown = 100 * per.get("unknown", 0) / total
        summary["unknown_pct"] = round(unknown, 1)
        summary["activity_seconds"] = round(time.time() - t, 1)
        report += ["## Activity", "", f"- Engine time: {summary['activity_seconds']} s, "
                   f"bouts: {s['tasks']['activity']['bouts']}", f"- Minutes labelled unknown: **{unknown:.1f} %**",
                   "", "| label | % of minutes |", "| --- | ---: |"]
        report += [f"| {k} | {100 * v / total:.1f} |" for k, v in sorted(per.items(), key=lambda x: -x[1])]
    except Exception:  # noqa: BLE001
        errors.append(traceback.format_exc())

    # 2. Calibration against logged workouts (override off).
    try:
        cal = calibrate.calibrate(str(work), now=now, tz=a.tz, days=a.days)
        summary["calibration"] = {k: v for k, v in cal.items() if not k.startswith("_") and v["workouts"]}
        report += ["", "## Detection vs logged workouts (workout override off)", "",
                   "| label | workouts | recall | precision (lower bound) |", "| --- | ---: | ---: | ---: |"]
        report += [f"| {k} | {v['workouts']} | {v['recall']} | {v['precision_lower_bound']} |"
                   for k, v in cal.items() if not k.startswith("_")]
        report += ["", "Confusion inside workouts: `" + json.dumps(cal["_confusion_in_workouts"]) + "`"]
        # Same, limited to workouts recorded by an Apple Watch (started by the user).
        calw = calibrate.calibrate(str(work), now=now, tz=a.tz, days=max(a.days, 90), source_like="%Watch%")
        summary["calibration_watch"] = {k: v for k, v in calw.items() if not k.startswith("_") and v["workouts"]}
        report += ["", "### Apple Watch workouts only (last 90 days)", "",
                   "| label | workouts | recall | precision (lower bound) |", "| --- | ---: | ---: | ---: |"]
        report += [f"| {k} | {v['workouts']} | {v['recall']} | {v['precision_lower_bound']} |"
                   for k, v in calw.items() if not k.startswith("_")]
        report += ["", "Confusion: `" + json.dumps(calw["_confusion_in_workouts"]) + "`"]
    except Exception:  # noqa: BLE001
        errors.append(traceback.format_exc())

    # 3. Wind-down plans for the last 30 evenings vs the sleep that followed.
    try:
        conn.execute("DELETE FROM inferences WHERE kind LIKE 'wind_down%'")
        conn.execute("DELETE FROM engine_state WHERE key LIKE 'wind_down.%'")
        conn.commit()
        last_day = datetime.fromtimestamp(now, zone).date()
        nights = {n.wake_date: n for n in sleep.nights(conn, a.tz, now - (a.days + 30) * 86400, now)}
        rows, diffs_onset, diffs_wake = [], [], []
        for k in range(a.days, 0, -1):
            evening = last_day - timedelta(days=k)
            ts = datetime(evening.year, evening.month, evening.day, 21, 0, tzinfo=zone).timestamp()
            fengshui_engine.run(str(work), now_ts=ts, tz=a.tz, where="server", tasks=["wind_down"])
            fengshui_engine.run(str(work), now_ts=ts + 14 * 3600, tz=a.tz, where="server", tasks=["wind_down_outcome"])
            v = json.loads(conn.execute("SELECT value_json FROM inferences WHERE kind='wind_down_plan' AND "
                                        "superseded_by IS NULL ORDER BY id DESC LIMIT 1").fetchone()[0])
            n = nights.get(evening + timedelta(days=1))
            if n:
                d_on = ((clock_min(n.onset, zone) - parse_hhmm(v["target_sleep_onset"]) + 720) % 1440) - 720
                d_wk = ((clock_min(n.wake, zone) - parse_hhmm(v["predicted_wake"]) + 720) % 1440) - 720
                diffs_onset.append(d_on)
                diffs_wake.append(d_wk)
            rows.append((evening, v, n))
        mae = lambda xs: statistics.mean(abs(x) for x in xs) if xs else None  # noqa: E731
        summary["nights_with_sleep"] = len(diffs_wake)
        summary["wake_mae_min"] = round(mae(diffs_wake), 1) if diffs_wake else None
        summary["onset_mae_min"] = round(mae(diffs_onset), 1) if diffs_onset else None
        summary["wake_within_30min_pct"] = round(100 * sum(abs(x) <= 30 for x in diffs_wake) / len(diffs_wake), 1) \
            if diffs_wake else None
        report += ["", "## Wind-down plans vs actual sleep", "",
                   f"- Nights with a main sleep: {len(diffs_wake)}/{a.days}",
                   f"- Predicted vs actual wake: mean abs error {summary['wake_mae_min']} min; "
                   f"within 30 min: {summary['wake_within_30min_pct']} %",
                   f"- Target vs actual sleep onset: mean abs difference {summary['onset_mae_min']} min "
                   "(a target is a recommendation, so this measures how far habit is from the plan)", "",
                   "| night | day type | wake pred/actual | onset target/actual | wind-down | conf |",
                   "| --- | --- | --- | --- | --- | --- |"]
        for evening, v, n in rows:
            act_w = datetime.fromtimestamp(n.wake, zone).strftime("%H:%M") if n else "—"
            act_o = datetime.fromtimestamp(n.onset, zone).strftime("%H:%M") if n else "—"
            report.append(f"| {evening} | {v['day_type_tomorrow']} | {v['predicted_wake']} / {act_w} | "
                          f"{v['target_sleep_onset']} / {act_o} | {v['wind_down_start']} | {v['nights_used']} |")
        outs = [json.loads(r[0]) for r in conn.execute("SELECT value_json FROM inferences WHERE kind='wind_down_outcome'")]
        summary["outcomes"] = len(outs)
        summary["followed_pct"] = round(100 * sum(o["followed"] for o in outs) / len(outs), 1) if outs else None
        length = conn.execute("SELECT value FROM engine_state WHERE key='wind_down.len'").fetchone()
        summary["wind_down_len"] = length[0] if length else None
        report += ["", f"- Outcomes recorded: {len(outs)}, followed: {summary['followed_pct']} %, "
                   f"wind-down length now {summary['wind_down_len']} min"]
    except Exception:  # noqa: BLE001
        errors.append(traceback.format_exc())

    # 4. Export rows that HealthKit sync could adopt later (D-06) — counted, not changed here.
    summary["export_rows"] = conn.execute("SELECT COUNT(*) FROM processed_samples WHERE hk_uuid LIKE 'export:%'").fetchone()[0]
    report += ["", "## Errors", ""] + ([f"```\n{e}\n```" for e in errors] or ["- none"])
    report += ["", f"Total time {time.time() - t_start:.0f} s."]
    (HE / "engine_check.md").write_text("\n".join(report) + "\n")
    conn.close()
    work.unlink(missing_ok=True)
    ok = not errors
    print(json.dumps({"ok": ok, **{k: v for k, v in summary.items() if k != "calibration"},
                      "calibration_recall": {k: v["recall"] for k, v in summary.get("calibration", {}).items()},
                      "watch_workout_recall": {k: v["recall"] for k, v in summary.get("calibration_watch", {}).items()}}))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
