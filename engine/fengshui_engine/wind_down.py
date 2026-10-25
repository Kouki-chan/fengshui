"""Tasks `wind_down` and `wind_down_outcome` (spec §10.2, `wind_down-v1`).

Each evening: when to start winding down = predicted wake − (sleep need + extra for
debt) − time to fall asleep − wind-down length − evening adjustments, with realism
guards. Each morning: compare last night with its plan and adapt the wind-down length.
The arithmetic lives in `compose()` so the spec's worked example is testable exactly.
"""

from __future__ import annotations

import json
import math
import sqlite3
import statistics
from datetime import date, datetime, time, timedelta
from zoneinfo import ZoneInfo

from . import config as C
from . import db, sleep
from .minute import minute_id

LEN_KEY = "wind_down.len"
ACTIVE_LABELS = {"walking", "running", "stairs", "cycling", "workout"}


# ---------------------------------------------------------------- small helpers

def weighted_median(values: list[float], weights: list[float]) -> float:
    pairs = sorted(zip(values, weights))
    total = sum(w for _, w in pairs)
    acc = 0.0
    for v, w in pairs:
        acc += w
        if acc >= total / 2:
            return v
    return pairs[-1][0]


def circular_weighted_median(minutes: list[float], weights: list[float]) -> float:
    """Weighted median of clock minutes (0–1440), safe across midnight: values are
    unwrapped around their circular mean first."""
    sx = sum(w * math.cos(2 * math.pi * m / 1440) for m, w in zip(minutes, weights))
    sy = sum(w * math.sin(2 * math.pi * m / 1440) for m, w in zip(minutes, weights))
    anchor = (math.atan2(sy, sx) * 1440 / (2 * math.pi)) % 1440
    unwrapped = [anchor + ((m - anchor + 720) % 1440) - 720 for m in minutes]
    return weighted_median(unwrapped, weights) % 1440


def circular_sd(minutes: list[float]) -> float:
    if len(minutes) < 2:
        return 0.0
    anchor = circular_weighted_median(minutes, [1.0] * len(minutes))
    return statistics.pstdev([((m - anchor + 720) % 1440) - 720 for m in minutes])


def clock_min(ts: float, zone: ZoneInfo) -> float:
    d = datetime.fromtimestamp(ts, zone)
    return d.hour * 60 + d.minute + d.second / 60


def hhmm(ts: float, zone: ZoneInfo) -> str:
    return datetime.fromtimestamp(round(ts / 60) * 60, zone).strftime("%H:%M")


def parse_hhmm(s: str) -> float:
    h, m = s.split(":")
    return int(h) * 60 + int(m)


def at_clock(d: date, minute: float, zone: ZoneInfo) -> float:
    """Timestamp of `minute` after local midnight of date d (DST-correct)."""
    midnight = datetime.combine(d, time(0), zone)
    return (midnight + timedelta(minutes=minute)).timestamp()


def nearest_clock(ref_ts: float, minute: float, zone: ZoneInfo) -> float:
    """The occurrence of clock `minute` closest to ref_ts."""
    d = datetime.fromtimestamp(ref_ts, zone).date()
    cands = [at_clock(d + timedelta(days=k), minute, zone) for k in (-1, 0, 1)]
    return min(cands, key=lambda t: abs(t - ref_ts))


def pref(conn, key: str):
    row = conn.execute("SELECT value_json FROM preferences WHERE key=?", (key,)).fetchone()
    return json.loads(row[0]) if row else None


# ---------------------------------------------------------------- day type (step 2)

class DayTyper:
    def __init__(self, conn: sqlite3.Connection, zone: ZoneInfo):
        self.zone = zone
        work = [r[0] for r in conn.execute("SELECT id FROM context_places WHERE kind='work'")]
        self.has_work = bool(work)
        self.work_dates: set[date] = set()
        first = conn.execute("SELECT MIN(arrival_ts) FROM context_visits").fetchone()[0]
        self.history_start = datetime.fromtimestamp(first, zone).date() if first else None
        if work:
            marks = ",".join("?" * len(work))
            for a, d in conn.execute(f"SELECT arrival_ts, departure_ts FROM context_visits WHERE place_id IN ({marks})", work):
                end = d if d is not None else a
                day = datetime.fromtimestamp(a, zone).date()
                while day <= datetime.fromtimestamp(end, zone).date():
                    self.work_dates.add(day)
                    day += timedelta(days=1)

    def __call__(self, d: date) -> str:
        weekday_default = "workday" if d.weekday() < 5 else "free"
        if not self.has_work or self.history_start is None:
            return weekday_default
        covered = sum(1 for k in range(1, C.WORKDAY_WEEKS + 1) if d - timedelta(days=7 * k) >= self.history_start)
        if covered < C.WORKDAY_MIN_WEEKS:
            # Not enough location history yet to apply the rule (DECISIONS D-12).
            return weekday_default
        weeks = sum(1 for k in range(1, C.WORKDAY_WEEKS + 1) if d - timedelta(days=7 * k) in self.work_dates)
        return "workday" if weeks >= C.WORKDAY_MIN_WEEKS else "free"


# ---------------------------------------------------------------- plan arithmetic (steps 5–6)

def compose(*, night_of: date, zone: ZoneInfo, wake_ts: float, need: float, debt: float, latency: float,
            wind_down_len: float, adjustments: list[dict], habitual_onset_ts: float | None,
            yesterday_onset_min: float | None) -> dict:
    extra = round(min(debt / C.EXTRA_DIVISOR, C.EXTRA_MAX_MIN))
    onset = wake_ts - (need + extra) * 60
    reasons = []
    if habitual_onset_ts is not None and onset < habitual_onset_ts - C.HABITUAL_MAX_EARLIER_MIN * 60:
        onset = habitual_onset_ts - C.HABITUAL_MAX_EARLIER_MIN * 60
        reasons.append("limited_by_habitual_onset")
    if yesterday_onset_min is not None:
        delta = ((clock_min(onset, zone) - yesterday_onset_min + 720) % 1440) - 720
        if abs(delta) > C.MAX_SHIFT_PER_NIGHT_MIN:
            onset -= (delta - math.copysign(C.MAX_SHIFT_PER_NIGHT_MIN, delta)) * 60
            reasons.append("limited_by_gradual_shift")
    in_bed = onset - latency * 60
    total_adj = max(-C.ADJUST_MAX_TOTAL_MIN, sum(a["minutes"] for a in adjustments))
    start = in_bed - wind_down_len * 60 + total_adj * 60
    return {"night_of": night_of.isoformat(), "predicted_wake": hhmm(wake_ts, zone),
            "sleep_need_min": round(need), "sleep_debt_min": round(debt), "extra_tonight_min": extra,
            "target_sleep_onset": hhmm(onset, zone), "target_in_bed": hhmm(in_bed, zone),
            "wind_down_start": hhmm(start, zone), "wind_down_len_min": round(wind_down_len),
            "adjustments": adjustments, "reasons": reasons,
            "_ts": {"wake": wake_ts, "onset": onset, "in_bed": in_bed, "start": start}}


# ---------------------------------------------------------------- inputs (steps 1–4, 7)

def _night_of(now: float, zone: ZoneInfo) -> date:
    """The evening this plan is for: today from noon, else last night (small hours)."""
    d = datetime.fromtimestamp(now, zone)
    return d.date() if d.hour >= 12 else d.date() - timedelta(days=1)


def _weight(age_days: float) -> float:
    return 0.5 ** (age_days / C.WAKE_HALF_LIFE_DAYS)


def plan(conn: sqlite3.Connection, now: float, tz: str) -> dict:
    zone = ZoneInfo(tz)
    night = _night_of(now, zone)
    tomorrow = night + timedelta(days=1)
    typer = DayTyper(conn, zone)
    nights = sleep.nights(conn, tz, now - C.NIGHTS_LOOKBACK * 86400, now)
    nights = [n for n in nights if n.wake_date <= night]
    dt = typer(tomorrow)
    onboarding = pref(conn, "onboarding_sleep") or {}
    cold = len(nights) < C.COLD_START_NIGHTS

    # Step 3: predicted wake.
    override = pref(conn, "wake_override")
    same = [n for n in nights if typer(n.wake_date) == dt]
    if override and override.get("date") == tomorrow.isoformat():
        wake_min = parse_hhmm(override["time"])
        wake_source = "override"
    elif not cold and same:
        wake_min = circular_weighted_median([clock_min(n.wake, zone) for n in same],
                                            [_weight((tomorrow - n.wake_date).days) for n in same])
        wake_source = "history"
    else:
        key = "workday_wake" if dt == "workday" else "freeday_wake"
        wake_min = parse_hhmm(onboarding.get(key, C.DEFAULT_COLD_WAKE))
        wake_source = "onboarding"
    wake_ts = at_clock(tomorrow, wake_min, zone)

    # Step 4: need and debt.
    free = [n.asleep_min for n in nights if typer(n.wake_date) == "free"]
    need = C.NEED_PRIOR_MIN if not free else \
        (len(free) * statistics.median(free) + C.NEED_PRIOR_WEIGHT * C.NEED_PRIOR_MIN) / (len(free) + C.NEED_PRIOR_WEIGHT)
    need = min(max(need, C.NEED_CLAMP[0]), C.NEED_CLAMP[1])
    recent = [n for n in nights if (tomorrow - n.wake_date).days <= C.DEBT_NIGHTS]
    debt = min(max(sum(need - n.asleep_min for n in recent), C.DEBT_CLAMP[0]), C.DEBT_CLAMP[1])

    # Step 5 inputs.
    lats = [n.latency_min for n in nights if n.latency_min is not None
            and (tomorrow - n.wake_date).days <= C.LATENCY_NIGHTS]
    latency = statistics.median(lats) if lats else C.LATENCY_DEFAULT_MIN
    latency = min(max(latency, C.LATENCY_CLAMP[0]), C.LATENCY_CLAMP[1])
    wd_len = float(db.get_state(conn, LEN_KEY, str(C.WIND_DOWN_LEN_DEFAULT)))

    # Step 6 inputs.
    hab_n = [n for n in nights if (tomorrow - n.wake_date).days <= C.HABITUAL_NIGHTS]
    if hab_n:
        hab_min = circular_weighted_median([clock_min(n.onset, zone) for n in hab_n],
                                           [_weight((tomorrow - n.wake_date).days) for n in hab_n])
    else:
        hab_min = (parse_hhmm(onboarding.get("bedtime", C.DEFAULT_COLD_BEDTIME)) + C.LATENCY_DEFAULT_MIN) % 1440
    habitual_ts = nearest_clock(wake_ts - (need + 0) * 60, hab_min, zone)
    y = conn.execute("SELECT value_json FROM inferences WHERE kind='wind_down_plan' AND superseded_by IS NULL "
                     "ORDER BY id DESC").fetchall()
    yesterday = next((json.loads(r[0]) for r in y
                      if json.loads(r[0])["night_of"] == (night - timedelta(days=1)).isoformat()), None)
    y_onset = parse_hhmm(yesterday["target_sleep_onset"]) if yesterday else None

    base = compose(night_of=night, zone=zone, wake_ts=wake_ts, need=need, debt=debt, latency=latency,
                   wind_down_len=wd_len, adjustments=[], habitual_onset_ts=habitual_ts, yesterday_onset_min=y_onset)

    # Step 7: evening adjustments, from 3 h before the (unadjusted) start.
    adjustments, reasons, home_prompt = [], [], False
    if now >= base["_ts"]["start"] - C.ADJUST_WINDOW_H * 3600:
        adjustments, reasons, home_prompt = _evening(conn, zone, now, base["_ts"]["in_bed"], base["_ts"]["start"], night)
    p = compose(night_of=night, zone=zone, wake_ts=wake_ts, need=need, debt=debt, latency=latency,
                wind_down_len=wd_len, adjustments=adjustments, habitual_onset_ts=habitual_ts,
                yesterday_onset_min=y_onset)
    p["reasons"] += reasons
    p["day_type_tomorrow"] = dt
    p["habitual_onset"] = f"{int(hab_min // 60):02d}:{int(hab_min % 60):02d}"
    p["nights_used"] = len(nights)
    p["wake_source"] = wake_source
    p["home_prompt"] = home_prompt
    p["_confidence"] = _confidence(nights, zone)
    return p


def _evening(conn, zone, now, in_bed_ts, start_ts, night) -> tuple[list[dict], list[str], bool]:
    adj, reasons = [], []
    lo = in_bed_ts - C.ADJUST_WINDOW_H * 3600
    bouts = [json.loads(r[0]) | {"_end": r[1] * 60, "_start": r[2] * 60} for r in conn.execute(
        "SELECT value_json, minute_end, minute_start FROM inferences WHERE kind='activity_bout' "
        "AND superseded_by IS NULL AND minute_end >= ? AND minute_start <= ?", (minute_id(lo), minute_id(now)))]
    hard = any(b["_end"] >= lo and (b["intensity"] in ("moderate", "vigorous") or b["label"] == "workout")
               and b["label"] not in ("sedentary", "sleep") for b in bouts)
    hard = hard or conn.execute("SELECT 1 FROM processed_samples WHERE label='workout' AND deleted=0 "
                                "AND end_ts BETWEEN ? AND ?", (lo, now)).fetchone() is not None
    if hard:
        adj.append({"reason": "evening_workout", "minutes": -C.ADJUST_WORKOUT_MIN})

    # Median HR over the last 30 min outside activity bouts vs 7-day resting HR.
    active = [(b["_start"], b["_end"]) for b in bouts if b["label"] in ACTIVE_LABELS]
    hrs = [v for v, s in conn.execute("SELECT value, start_ts FROM processed_samples WHERE label='heart_rate' "
                                      "AND deleted=0 AND start_ts BETWEEN ? AND ?",
                                      (now - C.ADJUST_HR_WINDOW_MIN * 60, now))
           if not any(a <= s < b for a, b in active)]
    rest = [r[0] for r in conn.execute("SELECT value FROM processed_samples WHERE label='resting_heart_rate' "
                                       "AND deleted=0 AND start_ts BETWEEN ? AND ?",
                                       (now - C.RESTING_HR_DAYS * 86400, now))]
    if hrs and rest and statistics.median(hrs) > statistics.median(rest) + C.ADJUST_HR_ABOVE_RESTING:
        adj.append({"reason": "elevated_evening_hr", "minutes": -C.ADJUST_HR_MIN})

    # Cap the total at 30 min earlier by trimming the last adjustment.
    total = sum(a["minutes"] for a in adj)
    if total < -C.ADJUST_MAX_TOTAL_MIN:
        adj[-1]["minutes"] += -C.ADJUST_MAX_TOTAL_MIN - total

    # Not at Home: no time change; the phone sends a second prompt on Home entry.
    home = conn.execute("SELECT id FROM context_places WHERE kind='home'").fetchone()
    cur = conn.execute("SELECT place_id FROM context_visits WHERE arrival_ts <= ? AND "
                       "(departure_ts IS NULL OR departure_ts >= ?) ORDER BY arrival_ts DESC LIMIT 1",
                       (max(now, start_ts), max(now, start_ts))).fetchone()
    home_prompt = False
    if home and (cur is None or cur[0] != home[0]):
        reasons.append("not_home")
        home_prompt = True
    d0 = at_clock(night, 0, zone)
    for (thr,) in conn.execute("SELECT threshold_min FROM context_screen_events WHERE schedule='evening' "
                               "AND ts BETWEEN ? AND ? ORDER BY threshold_min", (d0, now)):
        reasons.append(f"screen_time_evening_{thr}min")
    return adj, reasons, home_prompt


def _confidence(nights, zone) -> float:
    n = len(nights)
    conf = C.CONFIDENCE_HIGH
    for limit, value in C.CONFIDENCE:
        if n < limit:
            conf = value
            break
    if circular_sd([clock_min(x.wake, zone) for x in nights]) > C.CONFIDENCE_WAKE_SD_MIN:
        conf *= C.CONFIDENCE_WAKE_SD_FACTOR
    return round(conf, 3)


# ---------------------------------------------------------------- tasks

def run(conn: sqlite3.Connection, ctx: dict) -> dict:
    p = plan(conn, ctx["now_ts"], ctx["tz"])
    ts, conf = p.pop("_ts"), p.pop("_confidence")
    old = conn.execute("SELECT id, value_json, minute_start FROM inferences WHERE kind='wind_down_plan' "
                       "AND superseded_by IS NULL ORDER BY id DESC").fetchall()
    prev = next((r for r in old if json.loads(r[1])["night_of"] == p["night_of"]), None)
    if prev and abs(prev[2] * 60 - ts["start"]) <= C.SUPERSEDE_MIN_SHIFT_MIN * 60:
        return {"rows_written": 0, "wind_down_start": json.loads(prev[1])["wind_down_start"]}
    cur = conn.execute(
        "INSERT INTO inferences (kind, minute_start, minute_end, value_json, confidence, algorithm, algorithm_version,"
        " computed_at, computed_where) VALUES ('wind_down_plan', ?, ?, ?, ?, 'wind_down', ?, ?, ?)",
        (minute_id(ts["start"]), minute_id(ts["wake"]), json.dumps(p, sort_keys=True, separators=(",", ":")), conf,
         C.WIND_DOWN_VERSION, ctx["now_ts"], ctx["where"]))
    if prev:
        conn.execute("UPDATE inferences SET superseded_by=? WHERE id=?", (cur.lastrowid, prev[0]))
    return {"rows_written": 1, "wind_down_start": p["wind_down_start"], "superseded": prev is not None}


def run_outcome(conn: sqlite3.Connection, ctx: dict) -> dict:
    now, zone = ctx["now_ts"], ZoneInfo(ctx["tz"])
    plans = {}
    for r in conn.execute("SELECT value_json, minute_start FROM inferences WHERE kind='wind_down_plan' "
                          "AND superseded_by IS NULL ORDER BY id"):
        v = json.loads(r[0])
        plans[v["night_of"]] = (v, r[1] * 60)
    done = {json.loads(r[0])["night_of"] for r in conn.execute(
        "SELECT value_json FROM inferences WHERE kind='wind_down_outcome'")}
    nights = {n.wake_date: n for n in sleep.nights(conn, ctx["tz"], now - 4 * 86400, now)}
    written = 0
    for night_of, (v, start_ts) in sorted(plans.items()):
        if night_of in done:
            continue
        n = nights.get(date.fromisoformat(night_of) + timedelta(days=1))
        if n is None or n.wake > now:
            continue
        planned_in_bed = nearest_clock(start_ts + v["wind_down_len_min"] * 60, parse_hhmm(v["target_in_bed"]), zone)
        actual_in_bed = n.in_bed_start
        followed = (actual_in_bed if actual_in_bed is not None else n.onset) <= planned_in_bed + C.OUTCOME_FOLLOWED_SLACK_MIN * 60
        value = {"night_of": night_of, "planned_wind_down_start": v["wind_down_start"],
                 "planned_in_bed": v["target_in_bed"], "planned_onset": v["target_sleep_onset"],
                 "actual_in_bed": hhmm(actual_in_bed, zone) if actual_in_bed else None,
                 "actual_onset": hhmm(n.onset, zone), "actual_wake": hhmm(n.wake, zone),
                 "latency": n.latency_min, "asleep_min": n.asleep_min, "followed": followed}
        conn.execute("INSERT INTO inferences (kind, minute_start, minute_end, value_json, confidence, algorithm,"
                     " algorithm_version, computed_at, computed_where) VALUES ('wind_down_outcome', ?, ?, ?, NULL,"
                     " 'wind_down', ?, ?, ?)", (minute_id(n.onset), minute_id(n.wake),
                                                json.dumps(value, sort_keys=True, separators=(",", ":")),
                                                C.WIND_DOWN_VERSION, now, ctx["where"]))
        written += 1
    length = float(db.get_state(conn, LEN_KEY, str(C.WIND_DOWN_LEN_DEFAULT)))
    if written:
        # Step 8 learning: mean latency over the last 7 outcomes.
        lats = [json.loads(r[0])["latency"] for r in conn.execute(
            "SELECT value_json FROM inferences WHERE kind='wind_down_outcome' ORDER BY minute_start DESC LIMIT ?",
            (C.OUTCOME_LATENCY_NIGHTS,))]
        lats = [x for x in lats if x is not None]
        if lats:
            m = sum(lats) / len(lats)
            if m > C.OUTCOME_LONG_LATENCY_MIN:
                length = min(length + C.WIND_DOWN_LEN_STEP, C.WIND_DOWN_LEN_RANGE[1])
            elif m < C.OUTCOME_SHORT_LATENCY_MIN:
                length = max(length - C.WIND_DOWN_LEN_STEP, C.WIND_DOWN_LEN_RANGE[0])
        db.set_state(conn, LEN_KEY, str(length))
    return {"rows_written": written, "wind_down_len": length}
