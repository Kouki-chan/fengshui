"""Task `activity` (spec §10.1, `activity-v1`): one label per minute, smoothed into
bouts, stored as `activity_bout` rows plus one `activity_day` summary per local day.

Steps: (1) assemble per-minute evidence from HealthKit, raw features, phone motion and
visits; (2) score every label 0–1 (scoring documented in docs/ALGORITHMS.md); (3) Viterbi
with a constant switch penalty and fixed overrides (workouts, main sleep), then minimum
bout lengths; (4) intensity from heart-rate reserve; (5) place context; (6) incremental
re-labelling from (last finalized − 120 min) with provisional bouts superseded later.
"""

from __future__ import annotations

import json
import math
import sqlite3
import statistics
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

from . import config as C
from . import db, raw, sleep
from .minute import minute_id

LABELS = ["workout", "sleep", "watch_off", "sedentary", "light", "walking", "running", "stairs",
          "cycling", "in_vehicle", "unknown"]
L = {name: i for i, name in enumerate(LABELS)}
FIXED = {"workout", "sleep"}
STATE_KEY = "activity.last_finalized"
INF = float("inf")


# ---------------------------------------------------------------- evidence

@dataclass
class Window:
    start: int                      # first minute_id
    end: int                        # exclusive
    tz: ZoneInfo
    steps: list = field(default_factory=list)          # steps in minute (float) or None if unknown
    hr: list = field(default_factory=list)             # bpm (actual or interpolated) or None
    hr_actual: list = field(default_factory=list)      # bool: a real sample in the minute
    hrr: list = field(default_factory=list)
    feat: list = field(default_factory=list)           # raw_minute_features dict or None
    flights: list = field(default_factory=list)
    motion: list = field(default_factory=list)         # (activity, confidence) or None
    place: list = field(default_factory=list)          # place_id, -1 unnamed, None between
    fixed: list = field(default_factory=list)          # "workout" / "sleep" / None
    workout_id: list = field(default_factory=list)     # index into workouts
    workouts: list = field(default_factory=list)       # (uuid, type)
    places: dict = field(default_factory=dict)         # id -> (name, kind)
    visits: list = field(default_factory=list)         # (arrival_min, departure_min, place_id or -1)

    @property
    def n(self) -> int:
        return self.end - self.start


def _prorate(rows, w: Window, out: list) -> None:
    """Spread each sample's value over the minutes it spans, by overlap."""
    for value, s, e in rows:
        if value is None:
            continue
        if e <= s:
            m = minute_id(s) - w.start
            if 0 <= m < w.n:
                out[m] = (out[m] or 0.0) + value
            continue
        rate = value / (e - s)
        for mid in range(max(minute_id(s), w.start), min(minute_id(e - 1e-6), w.end - 1) + 1):
            ov = min(e, (mid + 1) * 60) - max(s, mid * 60)
            if ov > 0:
                out[mid - w.start] = (out[mid - w.start] or 0.0) + rate * ov


def load(conn: sqlite3.Connection, start: int, end: int, tz: str, now: float,
         workout_override: bool = True) -> Window:
    zone = ZoneInfo(tz)
    w = Window(start, end, zone)
    n = w.n
    t0, t1 = start * 60.0, end * 60.0
    w.steps, w.flights = [None] * n, [None] * n
    w.hr, w.hr_actual, w.hrr = [None] * n, [False] * n, [None] * n
    w.feat, w.motion, w.place, w.fixed, w.workout_id = [None] * n, [None] * n, [None] * n, [None] * n, [None] * n

    def samples(label):
        return conn.execute("SELECT value, start_ts, end_ts FROM processed_samples WHERE label=? AND deleted=0 "
                            "AND end_ts >= ? AND start_ts < ? ORDER BY start_ts", (label, t0, t1)).fetchall()

    def per_source_max(label: str, out: list) -> list:
        # Watch, iPhone and e.g. a ring all record the same steps: summing them double-counts
        # (HealthKit de-duplicates too). Prorate each source separately, keep the minute's maximum.
        rows = conn.execute("SELECT COALESCE(source_name, ''), value, start_ts, end_ts FROM processed_samples "
                            "WHERE label=? AND deleted=0 AND end_ts >= ? AND start_ts < ? ORDER BY start_ts",
                            (label, t0, t1)).fetchall()
        by_src: dict[str, list] = {}
        for src, v, a, b in rows:
            by_src.setdefault(src, []).append((v, a, b))
        for src_rows in by_src.values():
            tmp = [None] * n
            _prorate(src_rows, w, tmp)
            for i, v in enumerate(tmp):
                if v is not None and (out[i] is None or v > out[i]):
                    out[i] = v
        return [(v, a, b) for _, v, a, b in rows]

    steps = per_source_max("step_count", w.steps)
    # Zero steps is evidence only on local days where a step source was active.
    step_days = {datetime.fromtimestamp(s, zone).date() for _, s, _ in steps}
    for i in range(n):
        if w.steps[i] is None and datetime.fromtimestamp((start + i) * 60, zone).date() in step_days:
            w.steps[i] = 0.0
    per_source_max("flights_climbed", w.flights)

    # Heart rate: HealthKit samples + tier-3 session HR chunks, minute means.
    acc: dict[int, list[float]] = {}
    for v, s, _ in samples("heart_rate"):
        m = minute_id(s) - start
        if 0 <= m < n and v is not None:
            acc.setdefault(m, []).append(v)
    for mid, payload in conn.execute("SELECT minute_id, payload FROM raw_chunks WHERE sensor='hr_session' "
                                     "AND payload IS NOT NULL AND minute_id >= ? AND minute_id < ?", (start, end)):
        acc.setdefault(mid - start, []).extend(v[0] for v in raw.decode(payload).physical())
    for m, vs in acc.items():
        w.hr[m] = sum(vs) / len(vs)
        w.hr_actual[m] = True
    _interpolate(w.hr, C.HR_INTERP_MAX_GAP_MIN)

    rest_by_day = _resting(conn, zone, start, end)
    hr_max = C.MAX_HR_INTERCEPT - C.MAX_HR_SLOPE * _age(conn, now)
    for i in range(n):
        if w.hr[i] is not None:
            d = datetime.fromtimestamp((start + i) * 60, zone).date()
            rest = rest_by_day.get(d, C.DEFAULT_RESTING_HR)
            w.hrr[i] = max(0.0, (w.hr[i] - rest) / max(hr_max - rest, 1.0))

    for r in conn.execute("SELECT * FROM raw_minute_features WHERE minute_id >= ? AND minute_id < ?", (start, end)):
        w.feat[r["minute_id"] - start] = dict(r)

    segs = conn.execute("SELECT start_ts, end_ts, activity, confidence FROM context_motion "
                        "WHERE start_ts < ? ORDER BY start_ts", (t1,)).fetchall()
    for k, (s, e, act, conf) in enumerate(segs):
        e = e if e is not None else (segs[k + 1][0] if k + 1 < len(segs) else now)
        for mid in range(max(minute_id(s), start), min(minute_id(e - 1e-6), end - 1) + 1):
            w.motion[mid - start] = (act, conf)

    w.places = {r[0]: (r[1], r[2]) for r in conn.execute(
        "SELECT id, name, kind FROM context_places WHERE kind != 'suggested'")}
    for pid, a, d in conn.execute("SELECT place_id, arrival_ts, departure_ts FROM context_visits "
                                  "WHERE arrival_ts < ? AND (departure_ts IS NULL OR departure_ts >= ?) "
                                  "ORDER BY arrival_ts", (t1 + 86400, t0 - 86400)):
        pid = pid if pid in w.places else -1
        am, dm = minute_id(a), minute_id(d if d is not None else now)
        w.visits.append((am, dm, pid))
        for mid in range(max(am, start), min(dm, end - 1) + 1):
            w.place[mid - start] = pid

    # Overrides: main sleep (below workout), then logged workouts.
    for night in sleep.nights(conn, tz, t0 - 86400, t1 + 86400):
        for mid in range(max(minute_id(night.onset), start), min(minute_id(night.wake - 1e-6), end - 1) + 1):
            w.fixed[mid - start] = "sleep"
    workouts = conn.execute("SELECT hk_uuid, value_text, start_ts, end_ts FROM processed_samples "
                            "WHERE label='workout' AND deleted=0 AND end_ts >= ? AND start_ts < ? "
                            "ORDER BY start_ts", (t0, t1)).fetchall() if workout_override else []
    for uuid, typ, s, e in workouts:
        w.workouts.append((uuid, typ))
        for mid in range(max(minute_id(s), start), min(minute_id(e - 1e-6), end - 1) + 1):
            w.fixed[mid - start] = "workout"
            w.workout_id[mid - start] = len(w.workouts) - 1
    return w


def _interpolate(xs: list, max_gap: int) -> None:
    last = None
    for i, v in enumerate(xs):
        if v is None:
            continue
        if last is not None and 1 < i - last <= max_gap + 1:
            a, b = xs[last], v
            for k in range(last + 1, i):
                xs[k] = a + (b - a) * (k - last) / (i - last)
        last = i


def _resting(conn, zone, start, end) -> dict[date, float]:
    """7-day median of resting_heart_rate before each local day."""
    rows = conn.execute("SELECT value, start_ts FROM processed_samples WHERE label='resting_heart_rate' AND deleted=0 "
                        "AND start_ts >= ? AND start_ts < ?",
                        (start * 60 - (C.RESTING_HR_DAYS + 1) * 86400, end * 60)).fetchall()
    by_day = [(datetime.fromtimestamp(s, zone).date(), v) for v, s in rows if v]
    out = {}
    d = datetime.fromtimestamp(start * 60, zone).date()
    last = datetime.fromtimestamp(end * 60, zone).date()
    while d <= last:
        vals = [v for dd, v in by_day if d - timedelta(days=C.RESTING_HR_DAYS) <= dd <= d]
        if vals:
            out[d] = statistics.median(vals)
        d += timedelta(days=1)
    return out


def _age(conn, now: float) -> float:
    row = conn.execute("SELECT value FROM characteristics WHERE key='date_of_birth'").fetchone()
    try:
        dob = date.fromisoformat(row[0])
        return (datetime.fromtimestamp(now).date() - dob).days / 365.25
    except (TypeError, ValueError):
        return C.DEFAULT_AGE


# ---------------------------------------------------------------- scoring

def _phone(motion, label) -> float:
    if not motion or motion[0] != label:
        return 0.0
    conf = motion[1]
    return C.SCORE_PHONE_HIGH if conf >= 2 else C.SCORE_PHONE_MEDIUM if conf >= C.PHONE_CONF_MIN else C.SCORE_PHONE_LOW


def score_minutes(w: Window) -> tuple[list[list[float]], list[set]]:
    """Per minute: a score per label, and the set of sources that were usable."""
    n = w.n
    # watch_off needs ≥ 60 consecutive still minutes without any HR sample.
    still = [w.feat[i] is not None and w.feat[i].get("mag_sd_mg") is not None
             and w.feat[i]["mag_sd_mg"] < C.WATCH_OFF_SD_MG and not w.hr_actual[i] for i in range(n)]
    off = [False] * n
    i = 0
    while i < n:
        if still[i]:
            j = i
            while j < n and still[j]:
                j += 1
            if j - i >= C.WATCH_OFF_MIN_RUN:
                off[i:j] = [True] * (j - i)
            i = j
        else:
            i += 1

    scores, sources = [], []
    for i in range(n):
        sc = [0.0] * len(LABELS)
        src = set()
        steps = w.steps[i]
        f = w.feat[i] or {}
        enmo, cad, vert = f.get("enmo_mg"), f.get("cadence_hz"), f.get("vert_speed_m_min")
        motion, hrr = w.motion[i], w.hrr[i]
        if steps is not None:
            src.add("steps")
        if enmo is not None:
            src.add("accelerometer")
        if w.hr[i] is not None:
            src.add("heart_rate")
        if motion is not None:
            src.add("phone_motion")
        if w.place[i] is not None or w.visits:
            src.add("location")
        if w.fixed[i]:
            src.add(w.fixed[i])
            sc[L[w.fixed[i]]] = 1.0
            scores.append(sc)
            sources.append(src)
            continue
        if not (src - {"location"}):
            sc[L["unknown"]] = 1.0
            scores.append(sc)
            sources.append(src)
            continue

        sc[L["watch_off"]] = 1.0 if off[i] else 0.0

        run = 0.0
        if steps is not None and steps >= C.RUN_STEPS:
            run = 1.0
        elif steps is not None and steps >= C.RUN_STEPS_PARTIAL:
            run = C.SCORE_RUN_PARTIAL * (steps - C.RUN_STEPS_PARTIAL) / (C.RUN_STEPS - C.RUN_STEPS_PARTIAL)
        run = max(run, _phone(motion, "running"))
        if cad is not None and cad >= C.RUN_CADENCE_HZ and enmo is not None and enmo > C.RUN_ENMO_MG:
            run = 1.0
        sc[L["running"]] = run

        walk = 0.0
        if steps is not None:
            if C.WALK_STEPS_MIN <= steps < C.RUN_STEPS:
                walk = 1.0
            elif C.WALK_STEPS_PARTIAL <= steps < C.WALK_STEPS_MIN:
                walk = C.SCORE_ONE_SOURCE * (steps - C.WALK_STEPS_PARTIAL) / (C.WALK_STEPS_MIN - C.WALK_STEPS_PARTIAL)
            elif steps >= C.RUN_STEPS:
                walk = C.SCORE_WALK_FAST
        walk = max(walk, _phone(motion, "walking"))
        if cad is not None and C.WALK_CADENCE_HZ[0] <= cad < C.WALK_CADENCE_HZ[1] and enmo is not None \
                and C.WALK_ENMO_MG[0] <= enmo < C.WALK_ENMO_MG[1]:
            walk = max(walk, C.SCORE_RAW_WALK)
        sc[L["walking"]] = walk

        climbing = (w.flights[i] or 0) > 0 or (vert is not None and abs(vert) >= C.STAIRS_VERT_SPEED_M_MIN)
        sc[L["stairs"]] = max(walk, run) if climbing else 0.0
        if climbing and sc[L["stairs"]] > 0:
            sc[L["walking"]] = min(walk, C.SCORE_FLAT_WHEN_CLIMBING)
            sc[L["running"]] = min(run, C.SCORE_FLAT_WHEN_CLIMBING)

        cyc = _phone(motion, "cycling")
        if hrr is not None and (steps is None or steps < C.CYCLE_MAX_STEPS) and enmo is not None \
                and C.CYCLE_ENMO_MG[0] <= enmo <= C.CYCLE_ENMO_MG[1]:
            if hrr >= C.CYCLE_HRR:
                cyc = max(cyc, C.SCORE_CYCLE_HR)
            elif hrr >= C.CYCLE_HRR_PARTIAL:
                cyc = max(cyc, C.SCORE_CYCLE_PARTIAL)
        sc[L["cycling"]] = cyc

        veh = _phone(motion, "automotive")
        if w.place[i] is None and w.visits and enmo is not None and enmo < C.VEHICLE_ENMO_MG \
                and (steps is None or steps < C.VEHICLE_MAX_STEPS):
            veh = max(veh, C.SCORE_VEHICLE_INFERRED)
        sc[L["in_vehicle"]] = veh

        low_steps = steps is not None and steps < C.SEDENTARY_MAX_STEPS
        low_enmo = enmo is not None and enmo < C.SEDENTARY_ENMO_MG
        sed = 0.0
        if low_steps and low_enmo:
            sed = 1.0
        elif (low_steps and enmo is None) or (low_enmo and steps is None):
            sed = C.SCORE_TWO_SOURCES if _phone(motion, "stationary") else C.SCORE_ONE_SOURCE
        elif steps is None and enmo is None and motion and motion[0] == "stationary":
            sed = _phone(motion, "stationary") * C.SCORE_ONE_SOURCE
        sc[L["sedentary"]] = sed * (1 - veh)
        if off[i]:
            sc[L["sedentary"]] = min(sc[L["sedentary"]], C.SCORE_SED_WHEN_OFF)

        light = 0.0
        if enmo is not None and C.LIGHT_ENMO_MG[0] <= enmo < C.LIGHT_ENMO_MG[1] \
                and (steps is None or steps < C.LIGHT_MAX_STEPS):
            light = 1.0
        elif enmo is not None and C.LIGHT_ENMO_MG[1] <= enmo < 1.5 * C.LIGHT_ENMO_MG[1] \
                and (steps is None or steps < C.LIGHT_MAX_STEPS):
            light = C.SCORE_LIGHT_HIGH_ENMO
        elif steps is not None and C.SEDENTARY_MAX_STEPS <= steps < C.WALK_STEPS_PARTIAL \
                and (enmo is None or enmo < C.LIGHT_ENMO_MG[0]):
            # Some stepping but too few for walking; low ENMO alone doesn't make it sedentary.
            light = C.SCORE_LIGHT_STEPS_ONLY
        sc[L["light"]] = light
        if max(sc) == 0.0:
            sc[L["unknown"]] = C.SCORE_ONE_SOURCE
        scores.append(sc)
        sources.append(src)
    return scores, sources


# ---------------------------------------------------------------- smoothing

def viterbi(scores: list[list[float]], fixed: list) -> list[int]:
    """Most likely label path. Emission cost −log(score + ε); constant switch penalty;
    fixed minutes can only take their override label. O(n · labels)."""
    n, k = len(scores), len(LABELS)
    if n == 0:
        return []
    emis = []
    for i in range(n):
        if fixed[i]:
            row = [INF] * k
            row[L[fixed[i]]] = 0.0
        else:
            row = [-math.log(s + C.EMISSION_EPS) for s in scores[i]]
            for f in FIXED:
                row[L[f]] = INF
        emis.append(row)
    cost = emis[0][:]
    back: list[list[int]] = [[0] * k]
    for i in range(1, n):
        b = min(range(k), key=lambda j: cost[j])
        switch = cost[b] + C.SWITCH_PENALTY
        new, bp = [0.0] * k, [0] * k
        for j in range(k):
            if cost[j] <= switch:
                new[j], bp[j] = cost[j] + emis[i][j], j
            else:
                new[j], bp[j] = switch + emis[i][j], b
        cost = new
        back.append(bp)
    path = [min(range(k), key=lambda j: cost[j])]
    for i in range(n - 1, 0, -1):
        path.append(back[i][path[-1]])
    return path[::-1]


def to_bouts(path: list[int], w: Window) -> list[list]:
    """[label, start_index, end_index_exclusive]; workouts split per workout."""
    bouts: list[list] = []
    for i, lab in enumerate(path):
        name = LABELS[lab]
        key = (name, w.workout_id[i] if name == "workout" else None)
        if bouts and bouts[-1][3] == key:
            bouts[-1][2] = i + 1
        else:
            bouts.append([name, i, i + 1, key])
    return [b[:3] for b in bouts]


def enforce_min_lengths(bouts: list[list], scores: list[list[float]]) -> list[list]:
    """Merge short bouts into the neighbour whose label scores higher on average over
    the short bout's minutes. Fixed (override) bouts never change and never absorb."""
    while True:
        cands = [(b[2] - b[1], i) for i, b in enumerate(bouts)
                 if b[0] not in FIXED and b[0] in C.MIN_BOUT_MIN and b[2] - b[1] < C.MIN_BOUT_MIN[b[0]]]
        merged = False
        for _, i in sorted(cands):
            b = bouts[i]
            options = [j for j in (i - 1, i + 1) if 0 <= j < len(bouts) and bouts[j][0] not in FIXED]
            if not options:
                continue
            mean = lambda lab: sum(scores[m][L[lab]] for m in range(b[1], b[2])) / (b[2] - b[1])  # noqa: E731
            j = max(options, key=lambda j: (mean(bouts[j][0]), -abs(j - i)))
            b[0] = bouts[j][0]
            merged = True
            break
        # Coalesce neighbours with the same (non-workout) label.
        out: list[list] = []
        for b in bouts:
            if out and out[-1][0] == b[0] and b[0] != "workout":
                out[-1][2] = b[2]
            else:
                out.append(b)
        bouts = out
        if not merged:
            return bouts


# ---------------------------------------------------------------- description

def _iso(mid: int, zone: ZoneInfo) -> str:
    return datetime.fromtimestamp(mid * 60, zone).isoformat(timespec="minutes")


def _place_name(pid, w: Window) -> str:
    if pid is None:
        return "between places"
    if pid == -1:
        return "unnamed place"
    return w.places[pid][0]


def describe(b: list, w: Window, scores, sources, path) -> tuple[dict, float]:
    label, s, e = b
    idx = range(s, e)
    minutes = e - s
    steps = sum(w.steps[i] or 0 for i in idx)
    hrs = [w.hr[i] for i in idx if w.hr[i] is not None]
    hrrs = [w.hrr[i] for i in idx if w.hrr[i] is not None]
    intensity = None
    if label not in ("sleep", "watch_off", "unknown") and hrrs:
        m = sum(hrrs) / len(hrrs)
        intensity = "vigorous" if m >= C.INTENSITY_VIGOROUS_HRR else "moderate" if m >= C.INTENSITY_MODERATE_HRR else "light"
    if label == "walking" and steps / minutes >= C.BRISK_WALK_STEPS and intensity in (None, "light"):
        intensity = "moderate"

    # Place: majority over the bout's minutes.
    counts: dict = {}
    for i in idx:
        counts[w.place[i]] = counts.get(w.place[i], 0) + 1
    pid = max(counts, key=lambda k: (counts[k], k is not None))
    a0, a1 = w.start + s, w.start + e
    before = [v for v in w.visits if v[1] <= a0 + 1]
    after = [v for v in w.visits if v[0] >= a1 - 1]
    prev_p = before[-1][2] if before else None
    next_p = after[0][2] if after else None
    if pid is None:
        place = (f"near {w.places[prev_p][0]}" if prev_p is not None and prev_p == next_p and prev_p != -1
                 else "between places")
    else:
        place = f"at {_place_name(pid, w)}"
    frm = to = None
    if label == "in_vehicle":
        frm = _place_name(prev_p, w) if before else None
        to = _place_name(next_p, w) if after else None
        frm = None if frm == "between places" else frm
        to = None if to == "between places" else to

    srcs = sorted(set().union(*(sources[i] for i in idx)) - {"workout", "sleep"})
    wid = w.workout_id[s] if label == "workout" else None
    value = {"label": label, "intensity": intensity, "start": _iso(a0, w.tz), "end": _iso(a1, w.tz),
             "minutes": minutes, "steps": round(steps), "avg_hr": round(sum(hrs) / len(hrs)) if hrs else None,
             "place": place, "from": frm, "to": to,
             "workout_type": w.workouts[wid][1] if wid is not None else None, "sources": srcs}

    margins, multi = [], 0
    for i in idx:
        srt = sorted(scores[i], reverse=True)
        margins.append(srt[0] - srt[1])
        multi += len(sources[i] - {"location", "workout", "sleep"}) >= 2 or label in FIXED
    conf = (sum(margins) / minutes) * (multi / minutes)
    return value, round(min(1.0, conf), 3)


# ---------------------------------------------------------------- persistence

def _write(conn, kind: str, rows: list[tuple[int, int, dict, float | None, bool]], lo: int, hi: int,
           ctx: dict) -> int:
    """Insert rows that differ from the current non-superseded ones in [lo, hi);
    supersede the old rows they replace. Identical re-runs write nothing."""
    old = conn.execute("SELECT id, minute_start, minute_end, value_json, provisional FROM inferences "
                       "WHERE kind=? AND superseded_by IS NULL AND minute_end > ? AND minute_start < ? "
                       "ORDER BY minute_start", (kind, lo, hi)).fetchall()
    old_keys = {(r[1], r[2], r[3], r[4]): r[0] for r in old}
    keep, new_ids = set(), []
    written = 0
    for s, e, value, conf, prov in rows:
        vj = json.dumps(value, sort_keys=True, separators=(",", ":"))
        k = (s, e, vj, int(prov))
        if k in old_keys:
            keep.add(old_keys[k])
            continue
        algo, ver = ("wind_down", C.WIND_DOWN_VERSION) if kind.startswith("wind_down") else ("activity", C.ACTIVITY_VERSION)
        cur = conn.execute(
            "INSERT INTO inferences (kind, minute_start, minute_end, value_json, confidence, algorithm, "
            "algorithm_version, computed_at, computed_where, provisional) VALUES (?,?,?,?,?,?,?,?,?,?)",
            (kind, s, e, vj, conf, algo, ver, ctx["now_ts"], ctx["where"], int(prov)))
        new_ids.append((s, e, cur.lastrowid))
        written += 1
    for rid, s, e, _, _ in old:
        if rid in keep:
            continue
        repl = next((nid for ns, ne, nid in new_ids if ns < e and ne > s), new_ids[0][2] if new_ids else None)
        if repl is not None:
            conn.execute("UPDATE inferences SET superseded_by=? WHERE id=?", (repl, rid))
    return written


def run(conn: sqlite3.Connection, ctx: dict) -> dict:
    now, tz = ctx["now_ts"], ctx["tz"]
    zone = ZoneInfo(tz)
    end = minute_id(now)
    lf = db.get_state(conn, STATE_KEY)
    start = (int(lf) - C.REPROCESS_MIN) if lf else minute_id(now - C.ACTIVITY_FIRST_RUN_DAYS * 86400)
    # Start at the beginning of the stored bout that contains `start`, so no bout is cut.
    row = conn.execute("SELECT MIN(minute_start) FROM inferences WHERE kind='activity_bout' AND superseded_by IS NULL "
                       "AND minute_start <= ? AND minute_end > ?", (start, start)).fetchone()
    if row and row[0] is not None:
        start = row[0]
    if end - start < 1:
        return {"rows_written": 0}
    # calibrate.py turns the workout override off to measure detection against logged workouts.
    w = load(conn, start, end, tz, now, workout_override=ctx.get("workout_override", True))
    scores, sources = score_minutes(w)
    path = viterbi(scores, w.fixed)
    bouts = enforce_min_lengths(to_bouts(path, w), scores)
    prov_cut = minute_id(now - C.PROVISIONAL_MIN * 60)
    rows = []
    for b in bouts:
        value, conf = describe(b, w, scores, sources, path)
        rows.append((start + b[1], start + b[2], value, conf, start + b[2] > prov_cut))
    written = _write(conn, "activity_bout", rows, start, end, ctx)
    finals = [r[1] for r in rows if not r[4]]
    if finals:
        db.set_state(conn, STATE_KEY, str(max(finals)))
    written += _days(conn, zone, start, end, now, ctx)
    return {"rows_written": written, "minutes": end - start, "bouts": len(rows)}


def _days(conn, zone: ZoneInfo, start: int, end: int, now: float, ctx: dict) -> int:
    d = datetime.fromtimestamp(start * 60, zone).date()
    last = datetime.fromtimestamp((end - 1) * 60, zone).date()
    written = 0
    while d <= last:
        d0 = minute_id(datetime(d.year, d.month, d.day, tzinfo=zone).timestamp())
        nd = d + timedelta(days=1)
        d1 = minute_id(datetime(nd.year, nd.month, nd.day, tzinfo=zone).timestamp())
        bouts = [(r[0], r[1], json.loads(r[2])) for r in conn.execute(
            "SELECT minute_start, minute_end, value_json FROM inferences WHERE kind='activity_bout' "
            "AND superseded_by IS NULL AND minute_end > ? AND minute_start < ? ORDER BY minute_start", (d0, d1))]
        per: dict[str, int] = {}
        mvpa = longest_sed = steps = 0
        for s, e, v in bouts:
            m = min(e, d1) - max(s, d0)
            per[v["label"]] = per.get(v["label"], 0) + m
            if v["intensity"] in ("moderate", "vigorous"):
                mvpa += m
            if v["label"] == "sedentary":
                longest_sed = max(longest_sed, m)
            steps += v["steps"] * m / v["minutes"]
        elapsed = min(d1, minute_id(now)) - d0
        known = sum(m for k, m in per.items() if k != "unknown")
        value = {"date": d.isoformat(), "minutes": dict(sorted(per.items())), "mvpa_minutes": mvpa,
                 "longest_sedentary_min": longest_sed, "steps": round(steps), "watch_off_minutes": per.get("watch_off", 0),
                 "coverage_pct": round(100 * known / elapsed, 1) if elapsed > 0 else 0.0}
        written += _write(conn, "activity_day", [(d0, d1, value, None, now < d1 * 60)], d0, d1, ctx)
        d = nd
    return written
