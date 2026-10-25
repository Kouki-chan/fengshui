"""Synthetic data generator: realistic days for every test layer (spec §10, §14.1).

One generator writes fixtures/scenarios/<name>.json; Python tests and the Swift
fakes (`-FengshuiTestMode <scenario>`) read the same files, so both sides run on
identical days. Everything is seeded and deterministic.

A day is first planned as segments (start, end, activity, place), then turned
into HealthKit samples, iPhone motion, visits, workouts and, for the last days,
a raw-sensor plan that `raw_chunks()` renders into 50 Hz accelerometer chunks.

    .venv/bin/python engine/tests/synth.py          # regenerate all scenarios
"""

from __future__ import annotations

import json
import math
import random
import sys
from dataclasses import dataclass, field
from datetime import date, datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))

from fengshui_engine import raw as rawcodec  # noqa: E402
from fengshui_engine.minute import minute_id  # noqa: E402

OUT = ROOT / "fixtures" / "scenarios"

# Synthetic places in open countryside (not anyone's address).
HOME = {"name": "Home", "kind": "home", "lat": 40.10000, "lon": -75.20000, "radius_m": 150}
WORK = {"name": "Work", "kind": "work", "lat": 40.14500, "lon": -75.15500, "radius_m": 150}
GYM = (40.12000, -75.17000)        # unnamed place visited 3× → place suggestion
CAFE = (40.10900, -75.19100)

WATCH_SRC = ("Synthetic Watch", "com.apple.health.synthetic.watch",
             "name:Apple Watch, manufacturer:Apple Inc., model:Watch, hardware:Watch5,9, software:10.6.2")
PHONE_SRC = ("Synthetic iPhone", "com.apple.health.synthetic.phone",
             "name:iPhone, manufacturer:Apple Inc., model:iPhone, hardware:iPhone18,1, software:26.0.1")

# Per activity: (HR mean, steps/min, phone motion, truth label, raw kind)
ACT = {
    "sleep":     (52, 0, "stationary", "sleep", "sleep"),
    "sedentary": (66, 2, "stationary", "sedentary", "still"),
    "desk":      (68, 1, "stationary", "sedentary", "desk"),
    "light":     (84, 35, "stationary", "light", "light"),
    "walk":      (102, 112, "walking", "walking", "walk"),
    "brisk":     (112, 122, "walking", "walking", "walk"),
    "stairs":    (118, 95, "walking", "stairs", "stairs"),
    "run":       (152, 166, "running", "workout", "run"),
    "drive":     (72, 0, "automotive", "in_vehicle", "drive"),
    "cycle":     (128, 4, "cycling", "cycling", "cycle"),
    "off":       (None, 2, "stationary", "watch_off", "off"),
}


@dataclass
class Seg:
    start: float
    end: float
    act: str
    place: str | None = None          # "home" | "work" | "gym" | "cafe" | None (between)
    workout: str | None = None        # activity type when logged as a workout


@dataclass
class Scenario:
    name: str
    description: str
    tz: str = "America/New_York"
    seed: int = 1
    days: list = field(default_factory=list)     # list of (date, [Seg])
    watch: bool = True
    raw_days: int = 2
    sparse: float = 0.0                           # share of days without any watch data
    onboarding: dict = field(default_factory=dict)


# ---------------------------------------------------------------- day plans

def _t(d: date, hhmm: str, tz: ZoneInfo, plus_days: int = 0) -> float:
    h, m = map(int, hhmm.split(":"))
    return datetime(d.year, d.month, d.day, h, m, tzinfo=tz).timestamp() + plus_days * 86400


def plan_workday(d: date, tz: ZoneInfo, rnd: random.Random, run: bool) -> list[Seg]:
    j = lambda: rnd.randint(-8, 8) * 60  # noqa: E731 — minutes of jitter
    wake = _t(d, "07:00", tz) + j()
    s = [Seg(wake, wake + 50 * 60 + j(), "sedentary", "home")]
    s.append(Seg(s[-1].end, s[-1].end + 25 * 60, "light", "home"))
    s.append(Seg(s[-1].end, s[-1].end + 28 * 60 + j() // 2, "drive", None))
    s.append(Seg(s[-1].end, s[-1].end + 3 * 60, "walk", "work"))
    s.append(Seg(s[-1].end, s[-1].end + 2 * 60, "stairs", "work"))
    s.append(Seg(s[-1].end, _t(d, "12:10", tz) + j(), "desk", "work"))
    s.append(Seg(s[-1].end, s[-1].end + 20 * 60, "brisk", None))
    s.append(Seg(s[-1].end, s[-1].end + 15 * 60, "sedentary", "work"))
    s.append(Seg(s[-1].end, _t(d, "17:20", tz) + j(), "desk", "work"))
    s.append(Seg(s[-1].end, s[-1].end + 4 * 60, "walk", "work"))
    s.append(Seg(s[-1].end, s[-1].end + 30 * 60 + j() // 2, "drive", None))
    s.append(Seg(s[-1].end, s[-1].end + 20 * 60, "sedentary", "home"))
    if run:
        s.append(Seg(s[-1].end, s[-1].end + 34 * 60, "run", None, workout="running"))
        s.append(Seg(s[-1].end, s[-1].end + 10 * 60, "walk", None))
    s.append(Seg(s[-1].end, _t(d, "20:30", tz) + j(), "light", "home"))
    s.append(Seg(s[-1].end, s[-1].end + 70 * 60, "off", "home"))       # charging
    bed = _t(d, "23:20", tz) + j()
    s.append(Seg(s[-1].end, bed, "sedentary", "home"))
    return [x for x in s if x.end > x.start]


def plan_freeday(d: date, tz: ZoneInfo, rnd: random.Random, gym: bool, wake_at: str = "08:30") -> list[Seg]:
    j = lambda: rnd.randint(-10, 10) * 60  # noqa: E731
    wake = _t(d, wake_at, tz) + j()
    s = [Seg(wake, wake + 70 * 60, "sedentary", "home")]
    s.append(Seg(s[-1].end, s[-1].end + 45 * 60, "light", "home"))
    s.append(Seg(s[-1].end, s[-1].end + 25 * 60, "walk", None))
    s.append(Seg(s[-1].end, s[-1].end + 40 * 60, "sedentary", "cafe"))
    s.append(Seg(s[-1].end, s[-1].end + 25 * 60, "walk", None))
    if gym:
        s.append(Seg(s[-1].end, s[-1].end + 12 * 60, "drive", None))
        s.append(Seg(s[-1].end, s[-1].end + 45 * 60, "cycle", "gym", workout="cycling"))
        s.append(Seg(s[-1].end, s[-1].end + 12 * 60, "drive", None))
    s.append(Seg(s[-1].end, _t(d, "18:00", tz) + j(), "light", "home"))
    s.append(Seg(s[-1].end, s[-1].end + 75 * 60, "off", "home"))
    s.append(Seg(s[-1].end, _t(d, "23:50", tz) + j(), "sedentary", "home"))
    return [x for x in s if x.end > x.start]


def plan_shift(d: date, tz: ZoneInfo, rnd: random.Random) -> list[Seg]:
    """Night shift: sleep 08:00–15:00, work 22:00–06:30."""
    j = lambda: rnd.randint(-8, 8) * 60  # noqa: E731
    wake = _t(d, "15:00", tz) + j()
    s = [Seg(wake, wake + 90 * 60, "sedentary", "home"),
         Seg(wake + 90 * 60, _t(d, "21:25", tz), "light", "home")]
    s.append(Seg(s[-1].end, s[-1].end + 30 * 60, "drive", None))
    s.append(Seg(s[-1].end, _t(d, "02:00", tz, 1), "desk", "work"))
    s.append(Seg(s[-1].end, s[-1].end + 15 * 60, "walk", "work"))
    s.append(Seg(s[-1].end, _t(d, "06:30", tz, 1), "desk", "work"))
    s.append(Seg(s[-1].end, s[-1].end + 30 * 60, "drive", None))
    s.append(Seg(s[-1].end, _t(d, "07:50", tz, 1) + j(), "sedentary", "home"))
    return s


def add_sleep(segs: list[Seg], next_wake: float, last_end: float, place: str = "home") -> list[Seg]:
    return segs + [Seg(last_end, next_wake, "sleep", place)]


# ---------------------------------------------------------------- rendering

class Builder:
    def __init__(self, sc: Scenario):
        self.sc = sc
        self.rnd = random.Random(sc.seed)
        self.samples: list[list] = []
        self.workouts: list[dict] = []
        self.motion: list[list] = []
        self.visits: list[list] = []
        self.truth: list[list] = []
        self.raw_plan: list[list] = []
        self.onsets: dict[float, float] = {}   # in-bed start -> sleep onset
        self.n = 0

    def uid(self) -> str:
        self.n += 1
        r = self.rnd.getrandbits(48)
        return f"{self.sc.seed:08X}-{self.n >> 16 & 0xFFFF:04X}-4{self.n & 0xFFF:03X}-8000-{r:012X}"

    def sample(self, hk_type, value, value_text, unit, start, end, src, meta=None):
        self.samples.append([self.uid(), hk_type, value, value_text, unit, round(start, 3), round(end, 3),
                             src[0], src[1], src[2], meta])

    def render_day(self, segs: list[Seg], watch_on: bool, raw: bool) -> None:
        rnd = self.rnd
        for sg in segs:
            hr, spm, phone, truth, rawkind = ACT[sg.act]
            dur = sg.end - sg.start
            if sg.workout and not watch_on:
                truth = {"running": "running", "cycling": "cycling"}[sg.workout]   # no workout logged
            if sg.act == "sleep" and dur < 3 * 3600:
                self.truth.append([sg.start, sg.end, "sedentary"])                  # a nap, not main sleep
            elif sg.act == "sleep" and sg.start in self.onsets:
                self.truth.append([sg.start, self.onsets[sg.start], "sedentary"])
                self.truth.append([self.onsets[sg.start], sg.end, "sleep"])
            else:
                self.truth.append([sg.start, sg.end, "workout" if sg.workout and watch_on else truth])
            if raw and watch_on:
                self.raw_plan.append([sg.start, sg.end, rawkind])
            # iPhone motion (the phone stays still on the desk / nightstand).
            conf = 2 if sg.act not in ("light", "stairs") else 1
            self.motion.append([sg.start, sg.end, phone, conf])
            # Steps: chunked like Apple does (≤ 10 min per sample).
            if spm:
                src = WATCH_SRC if watch_on else PHONE_SRC
                t = sg.start
                while t < sg.end - 1:
                    e = min(t + 600, sg.end)
                    steps = max(0, round(spm * (e - t) / 60 * rnd.uniform(0.9, 1.1)))
                    if steps:
                        self.sample("HKQuantityTypeIdentifierStepCount", steps, None, "count", t, e, src)
                    t = e
            if sg.act == "stairs":
                self.sample("HKQuantityTypeIdentifierFlightsClimbed", max(1, round(dur / 60)), None, "count",
                            sg.start, sg.end, PHONE_SRC)
            if not watch_on or hr is None:
                continue
            # Heart rate: background cadence ~5 min, every 5 s during workouts.
            step = 5 if sg.workout else 300
            t = sg.start + rnd.uniform(0, min(step, dur))
            while t < sg.end:
                v = hr + rnd.gauss(0, 3 if not sg.workout else 6)
                if sg.workout:
                    v += 10 * min(1.0, (t - sg.start) / 300)  # warm-up ramp
                self.sample("HKQuantityTypeIdentifierHeartRate", round(v), None, "count/min", t, t, WATCH_SRC,
                            {"HKMetadataKeyHeartRateMotionContext": 2 if sg.workout else 1})
                t += step + (rnd.uniform(-60, 60) if not sg.workout else 0)
            if sg.workout:
                self.workout(sg)

    def workout(self, sg: Seg) -> None:
        uid = self.uid()
        dist = (2.9 if sg.workout == "running" else 6.0) * (sg.end - sg.start)
        route = []
        if sg.workout == "running":
            lat, lon = HOME["lat"] + 0.002, HOME["lon"]
            for i in range(0, int(sg.end - sg.start), 10):
                a = 2 * math.pi * i / (sg.end - sg.start)
                route.append([sg.start + i, round(lat + 0.006 * math.sin(a), 6), round(lon + 0.008 * (1 - math.cos(a)), 6),
                              round(60 + 5 * math.sin(a), 1), 2.9, 5.0])
        self.workouts.append({"uuid": uid, "activity": sg.workout, "start": sg.start, "end": sg.end,
                              "energy_kcal": round((sg.end - sg.start) / 60 * (11 if sg.workout == "running" else 8)),
                              "distance_m": round(dist), "source": WATCH_SRC[0], "route": route})

    def sleep(self, onset_in_bed: float, wake: float, watch_on: bool, phone_only: bool) -> None:
        """in_bed, then 90-min cycles of core/deep/core/rem with short awakenings."""
        rnd = self.rnd
        src = WATCH_SRC if watch_on else PHONE_SRC
        latency = rnd.uniform(8, 25) * 60
        self.sample("HKCategoryTypeIdentifierSleepAnalysis", 0, "in_bed", None, onset_in_bed, wake, src)
        t = onset_in_bed + latency
        self.onsets[onset_in_bed] = t
        if phone_only:
            self.sample("HKCategoryTypeIdentifierSleepAnalysis", 1, "asleep_unspecified", None, t, wake - 300, src)
            return
        cycle = 0
        while t < wake - 600:
            parts = [("asleep_core", 25), ("asleep_deep", 30 if cycle < 2 else 10), ("asleep_core", 20),
                     ("asleep_rem", 15 + 8 * cycle)]
            for name, mins in parts:
                e = min(t + mins * 60 * rnd.uniform(0.8, 1.2), wake)
                if e - t > 60:
                    self.sample("HKCategoryTypeIdentifierSleepAnalysis", {"asleep_core": 3, "asleep_deep": 4,
                                "asleep_rem": 5}[name], name, None, t, e, src)
                t = e
            if t < wake - 600 and rnd.random() < 0.5:
                e = t + rnd.uniform(2, 6) * 60
                self.sample("HKCategoryTypeIdentifierSleepAnalysis", 2, "awake", None, t, e, src)
                t = e
            cycle += 1

    def daily(self, d: date, tz: ZoneInfo, watch_on: bool) -> None:
        if not watch_on:
            return
        t0 = _t(d, "00:00", tz)
        self.sample("HKQuantityTypeIdentifierRestingHeartRate", round(56 + self.rnd.gauss(0, 1.5)), None,
                    "count/min", t0, t0 + 86340, WATCH_SRC)
        for h in (3, 14):
            t = t0 + h * 3600
            self.sample("HKQuantityTypeIdentifierHeartRateVariabilitySDNN", round(self.rnd.uniform(35, 65), 2), None,
                        "ms", t, t + 60, WATCH_SRC)

    def visit_track(self, segs: list[Seg]) -> None:
        coords = {"home": (HOME["lat"], HOME["lon"]), "work": (WORK["lat"], WORK["lon"]), "gym": GYM, "cafe": CAFE}
        cur = None
        for sg in segs:
            if sg.place != (cur[0] if cur else None):
                if cur:
                    self.visits.append([cur[1], sg.start, *cur[2], 30.0])
                cur = (sg.place, sg.start, coords[sg.place]) if sg.place else None
        if cur:
            self.visits.append([cur[1], None, *cur[2], 30.0])


def build(sc: Scenario, start: date, n_days: int, kind: str) -> dict:
    tz = ZoneInfo(sc.tz)
    b = Builder(sc)
    rnd = b.rnd
    all_segs: list[Seg] = []
    plans = []
    for i in range(n_days):
        d = start + timedelta(days=i)
        wd = d.weekday() < 5
        if kind == "shift":
            # Free day after a night shift starts mid-afternoon.
            plans.append((d, plan_shift(d, tz, rnd) if wd or d.weekday() == 6
                          else plan_freeday(d, tz, rnd, False, wake_at="14:00")))
        else:
            plans.append((d, plan_workday(d, tz, rnd, run=d.weekday() in (1, 3)) if wd
                          else plan_freeday(d, tz, rnd, gym=d.weekday() == 5)))
    for i, (d, segs) in enumerate(plans):
        watch_on = sc.watch and not (sc.sparse and rnd.random() < sc.sparse)
        raw = i >= n_days - sc.raw_days
        if i + 1 < len(plans):
            nxt = plans[i + 1][1][0].start
            segs = add_sleep(segs, nxt, segs[-1].end)
            b.sleep(segs[-1].start, nxt, watch_on, phone_only=not sc.watch)
        b.render_day(segs, watch_on, raw)
        b.daily(d, tz, watch_on)
        all_segs += segs
    b.visit_track(all_segs)
    # "now" = 21:00 local on the last day: in time for tonight's wind-down plan.
    last = start + timedelta(days=n_days - 1)
    now = _t(last, "21:00", tz) if n_days else _t(start, "12:00", tz)
    b.samples.sort(key=lambda r: r[5])
    b.samples = [r for r in b.samples if r[5] <= now]
    return {
        "name": sc.name, "description": sc.description, "tz": sc.tz, "seed": sc.seed,
        "start_day": start.isoformat(), "days": n_days, "now": now,
        "characteristics": {"date_of_birth": "1991-05-17", "biological_sex": "female"},
        "onboarding": sc.onboarding or {"workday_wake": "07:00", "freeday_wake": "08:30", "bedtime": "23:15"},
        "places": [HOME, WORK],
        "sample_columns": ["uuid", "hk_type", "value", "value_text", "unit", "start", "end",
                           "source", "source_bundle", "device", "metadata"],
        "samples": b.samples,
        "workouts": [w for w in b.workouts if w["end"] <= now],
        "motion_columns": ["start", "end", "activity", "confidence"],
        "motion": [m for m in b.motion if m[0] <= now],
        "visit_columns": ["arrival", "departure", "lat", "lon", "h_accuracy"],
        "visits": [v if (v[1] is None or v[1] <= now) else [v[0], None, *v[2:]] for v in b.visits if v[0] <= now],
        "raw_plan_columns": ["start", "end", "kind"],
        "raw_plan": [[s, min(e, now), k] for s, e, k in b.raw_plan if s < now],
        "truth_columns": ["start", "end", "label"],
        "truth": [[s, min(e, now), k] for s, e, k in b.truth if s < now],
    }


SCENARIOS = {
    "new_user": lambda: build(Scenario("new_user", "First launch, no data at all.", seed=11, raw_days=0),
                              date(2026, 10, 24), 0, "normal"),
    "typical_week": lambda: build(Scenario("typical_week", "Four weeks of an office worker: commutes, lunch walks, "
                                           "Tue/Thu runs, Sat gym cycling, nightly charging; raw data for the last 2 days.",
                                           seed=1), date(2026, 9, 27), 28, "normal"),
    "no_watch_data": lambda: build(Scenario("no_watch_data", "iPhone only: steps, phone motion, phone sleep schedule; "
                                            "no watch samples or raw data.", seed=2, watch=False, raw_days=0),
                                   date(2026, 10, 11), 14, "normal"),
    "shift_worker": lambda: build(Scenario("shift_worker", "Night shifts (22:00–06:30), daytime sleep.", seed=3,
                                           onboarding={"workday_wake": "15:00", "freeday_wake": "10:00",
                                                       "bedtime": "08:00"}),
                                  date(2026, 10, 4), 21, "shift"),
    "sparse_data": lambda: build(Scenario("sparse_data", "Two weeks where the watch is often not worn (≈45% of days).",
                                          seed=4, sparse=0.45), date(2026, 10, 11), 14, "normal"),
}


# ---------------------------------------------------------------- raw sensor rendering

def accel_minute(kind: str, t0: float, rnd: random.Random, rate: float = 50.0) -> list[tuple[float, float, float]]:
    """One minute of wrist accelerometer (g) for a raw-plan kind."""
    n = int(rate * 60)
    out = []
    gx, gy, gz = 0.0, 0.0, -1.0
    if kind == "sleep" and rnd.random() < 0.15:     # occasional turn-over changes orientation
        gx, gz = 0.6, -0.8
    f = {"walk": 1.85, "stairs": 1.6, "run": 2.75, "cycle": 1.3}.get(kind)
    amp = {"walk": 0.32, "stairs": 0.38, "run": 0.95, "cycle": 0.16, "light": 0.12, "drive": 0.025,
           "desk": 0.012, "still": 0.006, "sleep": 0.004, "off": 0.0015}[kind]
    phase = rnd.uniform(0, 2 * math.pi)
    for i in range(n):
        t = i / rate
        if f:
            s = math.sin(2 * math.pi * f * t + phase)
            h = 0.35 * math.sin(4 * math.pi * f * t + phase)  # heel-strike harmonic
            a = amp * (s + h)
            out.append((gx + 0.4 * a + rnd.gauss(0, 0.02), gy + 0.2 * a + rnd.gauss(0, 0.02),
                        gz + a + rnd.gauss(0, 0.02)))
        elif kind == "light":
            burst = amp * (1.5 if (i // 150) % 3 == 0 else 0.6)
            out.append((gx + rnd.gauss(0, burst), gy + rnd.gauss(0, burst), gz + rnd.gauss(0, burst)))
        else:
            out.append((gx + rnd.gauss(0, amp), gy + rnd.gauss(0, amp), gz + rnd.gauss(0, amp)))
    return out


def raw_chunks(scenario: dict, *, seed: int | None = None, snapshots: bool = True):
    """Yield (minute_id, sensor, tier, encoded_payload, sample_count) for the scenario's raw plan.
    Tier 1 accel every minute; tier 2 baro/gyro/compass 5 s snapshots at the top of each hour."""
    rnd = random.Random(scenario["seed"] if seed is None else seed)
    for start, end, kind in scenario["raw_plan"]:
        m0, m1 = minute_id(start), minute_id(end)
        for mid in range(m0, m1):
            t0 = mid * 60.0
            vals = accel_minute(kind, t0, rnd)
            if kind == "off" and rnd.random() < 0.02:
                vals = vals[: len(vals) // 2]                 # partial minute while taking it off
            chunk = rawcodec.RawChunk("accel", t0, 50.0, rawcodec.quantize("accel", vals))
            yield mid, "accel", 1, rawcodec.encode(chunk), len(chunk.samples)
            if snapshots and mid % 60 == 0:
                alt = {"stairs": 3.0, "walk": 0.2}.get(kind, 0.0)
                baro = [(101.3 - 0.012 * alt * i / 125 + rnd.gauss(0, 0.0003),) for i in range(125)]
                gyro = [tuple(rnd.gauss(0, 0.6 if kind in ("walk", "run") else 0.02) for _ in range(3)) for _ in range(125)]
                comp = [((90 + (30 * math.sin(i / 20) if kind in ("walk", "run") else 0)) % 360,) for i in range(125)]
                for sensor, v in (("baro", baro), ("gyro", gyro), ("compass", comp)):
                    c = rawcodec.RawChunk(sensor, t0, 25.0, rawcodec.quantize(sensor, v))
                    yield mid, sensor, 2, rawcodec.encode(c), len(c.samples)


def write_all() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    for name, fn in SCENARIOS.items():
        sc = fn()
        (OUT / f"{name}.json").write_text(json.dumps(sc, separators=(",", ":"), ensure_ascii=False))
        print(f"{name}: {len(sc['samples'])} samples, {len(sc['workouts'])} workouts, "
              f"{len(sc['motion'])} motion, {len(sc['visits'])} visits, {len(sc['raw_plan'])} raw segments")


def load(name: str) -> dict:
    return json.loads((OUT / f"{name}.json").read_text())


if __name__ == "__main__":
    write_all()
