import json
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

import pytest

import fengshui_engine
from fengshui_engine import config as C
from fengshui_engine import db
from fengshui_engine import wind_down as W

NY = ZoneInfo("America/New_York")


def test_worked_example_from_spec():
    """Spec §10.2: 08:05 − (472 + 32) = 23:41; − 14 latency = 23:27; − 60 − 15 = 22:12."""
    wake = datetime(2026, 10, 25, 8, 5, tzinfo=NY).timestamp()
    p = W.compose(night_of=date(2026, 10, 24), zone=NY, wake_ts=wake, need=472, debt=95, latency=14,
                  wind_down_len=60, adjustments=[{"reason": "evening_workout", "minutes": -15}],
                  habitual_onset_ts=datetime(2026, 10, 25, 0, 10, tzinfo=NY).timestamp(), yesterday_onset_min=None)
    assert p["extra_tonight_min"] == 32
    assert (p["predicted_wake"], p["target_sleep_onset"], p["target_in_bed"], p["wind_down_start"]) == \
           ("08:05", "23:41", "23:27", "22:12")
    assert p["sleep_need_min"] == 472 and p["sleep_debt_min"] == 95 and p["wind_down_len_min"] == 60
    assert p["reasons"] == []


def test_realism_guards():
    wake = datetime(2026, 10, 25, 6, 0, tzinfo=NY).timestamp()
    hab = datetime(2026, 10, 25, 0, 30, tzinfo=NY).timestamp()
    # Need 540 → onset 21:00, far earlier than habitual 00:30 − 60 → clamped to 23:30.
    p = W.compose(night_of=date(2026, 10, 24), zone=NY, wake_ts=wake, need=540, debt=0, latency=15,
                  wind_down_len=60, adjustments=[], habitual_onset_ts=hab, yesterday_onset_min=None)
    assert p["target_sleep_onset"] == "23:30" and "limited_by_habitual_onset" in p["reasons"]
    # Yesterday's target was 00:20 → at most 30 min shift → 23:50.
    p = W.compose(night_of=date(2026, 10, 24), zone=NY, wake_ts=wake, need=540, debt=0, latency=15,
                  wind_down_len=60, adjustments=[], habitual_onset_ts=hab, yesterday_onset_min=20)
    assert p["target_sleep_onset"] == "23:50" and "limited_by_gradual_shift" in p["reasons"]


def test_adjustments_capped_at_30():
    wake = datetime(2026, 10, 25, 8, 0, tzinfo=NY).timestamp()
    adj = [{"reason": "a", "minutes": -15}, {"reason": "b", "minutes": -15}, {"reason": "c", "minutes": -15}]
    p = W.compose(night_of=date(2026, 10, 24), zone=NY, wake_ts=wake, need=480, debt=0, latency=15,
                  wind_down_len=60, adjustments=adj, habitual_onset_ts=None, yesterday_onset_min=None)
    assert p["wind_down_start"] == "22:15"     # 00:00 − 15 − 60 − 30


def test_circular_median_across_midnight():
    assert W.circular_weighted_median([1430, 10, 20], [1, 1, 1]) == pytest.approx(10)
    assert W.circular_weighted_median([1380, 1390, 30], [1, 1, 5]) == pytest.approx(30)
    assert W.circular_sd([1430, 10]) == pytest.approx(10)


# ---------------------------------------------------------------- scenario-level

def run(path, sc, now=None, tasks=("activity", "wind_down_outcome", "wind_down")):
    return fengshui_engine.run(str(path), now_ts=now or sc["now"], tz=sc["tz"], where="phone", tasks=list(tasks))


def plans(conn, kind="wind_down_plan", live=True):
    q = "SELECT value_json, confidence, superseded_by FROM inferences WHERE kind=?" + \
        (" AND superseded_by IS NULL" if live else "") + " ORDER BY id"
    return [(json.loads(r[0]), r[1], r[2]) for r in conn.execute(q, (kind,))]


def test_typical_week_plan(built, tmp_path):
    p, sc = built("typical_week", tmp_path, raw=False)
    run(p, sc)
    (v, conf, _), = plans(db.connect(str(p)))
    assert v["night_of"] == "2026-10-24" and v["day_type_tomorrow"] == "free"     # Saturday night → Sunday
    assert "08:00" <= v["predicted_wake"] <= "08:45"                              # free-day wakes ~08:30
    assert C.NEED_CLAMP[0] <= v["sleep_need_min"] <= C.NEED_CLAMP[1]
    assert v["nights_used"] >= 20 and conf == C.CONFIDENCE_HIGH
    assert set(v) >= {"night_of", "day_type_tomorrow", "predicted_wake", "sleep_need_min", "sleep_debt_min",
                      "extra_tonight_min", "target_sleep_onset", "target_in_bed", "wind_down_start",
                      "wind_down_len_min", "adjustments", "habitual_onset", "nights_used", "reasons"}


def test_workday_prediction(built, tmp_path):
    """Sunday evening → Monday is a workday with a ~07:00 wake."""
    p, sc = built("typical_week", tmp_path, raw=False)
    sunday_evening = sc["now"] - 6 * 86400 - 3600      # Sun 2026-10-18 20:00
    run(p, sc, now=sunday_evening, tasks=("wind_down",))
    (v, _, _), = plans(db.connect(str(p)))
    assert v["day_type_tomorrow"] == "workday" and "06:45" <= v["predicted_wake"] <= "07:15"


def test_shift_worker_daytime_sleep(built, tmp_path):
    p, sc = built("shift_worker", tmp_path, raw=False)
    run(p, sc)
    (v, _, _), = plans(db.connect(str(p)))
    assert "14:30" <= v["predicted_wake"] <= "15:30"
    assert "05:00" <= v["wind_down_start"] <= "08:00"     # winds down after the night shift


def test_cold_start_uses_onboarding(built, tmp_path):
    p, sc = built("new_user", tmp_path, raw=False)
    run(p, sc)
    (v, conf, _), = plans(db.connect(str(p)))
    assert v["predicted_wake"] == sc["onboarding"]["freeday_wake"] and v["nights_used"] == 0
    assert conf == 0.3 and v["sleep_need_min"] == 480 and v["wake_source"] == "onboarding"


def test_day_type_falls_back_until_history(built, tmp_path):
    p, sc = built("no_watch_data", tmp_path, raw=False)
    conn = db.connect(str(p))
    typer = W.DayTyper(conn, NY)
    start = date.fromisoformat(sc["start_day"])
    first_monday = start + timedelta(days=(7 - start.weekday()) % 7)
    assert typer(first_monday) == "workday"                      # no history yet → weekday default
    assert typer(first_monday + timedelta(days=5)) == "free"     # Saturday


def test_wake_override(built, tmp_path):
    p, sc = built("typical_week", tmp_path, raw=False)
    conn = db.connect(str(p))
    conn.execute("INSERT INTO preferences (key, value_json, updated_at) VALUES ('wake_override', ?, 0)",
                 (json.dumps({"date": "2026-10-25", "time": "06:15"}),))
    run(p, sc, tasks=("wind_down",))
    (v, _, _), = plans(conn)
    assert v["predicted_wake"] == "06:15" and v["wake_source"] == "override"


def test_evening_workout_and_hr_adjust_and_supersede(built, tmp_path):
    p, sc = built("typical_week", tmp_path, raw=False)
    conn = db.connect(str(p))
    early = sc["now"] - 4 * 3600                     # 17:00: more than 3 h before wind-down → no adjustments
    run(p, sc, now=early)
    (v0, _, _), = plans(conn)
    assert v0["adjustments"] == []
    # Evening: a hard workout ended at 20:40 and HR stays high afterwards.
    now = sc["now"] + 1800
    conn.execute("INSERT INTO processed_samples (hk_uuid, hk_type, label, value, value_text, unit, start_ts, end_ts,"
                 " minute_id, inserted_at) VALUES ('w-late','HKWorkoutTypeIdentifier','workout',2400,'running','s',?,?,?,0)",
                 (now - 3000, now - 600, int((now - 3000) // 60)))
    for i in range(6):
        t = now - 600 + i * 100
        conn.execute("INSERT INTO processed_samples (hk_uuid, hk_type, label, value, unit, start_ts, end_ts, minute_id,"
                     " inserted_at) VALUES (?, 'HKQuantityTypeIdentifierHeartRate', 'heart_rate', 95, 'count/min', ?, ?, ?, 0)",
                     (f"hr-late-{i}", t, t, int(t // 60)))
    run(p, sc, now=now, tasks=("wind_down",))
    live = plans(conn)
    assert len(live) == 1
    v1 = live[0][0]
    assert [a["reason"] for a in v1["adjustments"]] == ["evening_workout", "elevated_evening_hr"]
    assert sum(a["minutes"] for a in v1["adjustments"]) == -30
    allp = plans(conn, live=False)
    assert len(allp) == 2 and allp[0][2] is not None         # first plan superseded (moved > 5 min)
    # Re-run with nothing new: no new row.
    run(p, sc, now=now + 60, tasks=("wind_down",))
    assert len(plans(conn, live=False)) == 2


def test_not_home_reason(built, tmp_path):
    p, sc = built("typical_week", tmp_path, raw=False)
    conn = db.connect(str(p))
    conn.execute("UPDATE context_visits SET departure_ts = ? WHERE departure_ts IS NULL", (sc["now"] - 600,))
    run(p, sc, tasks=("wind_down",))
    (v, _, _), = plans(conn)
    assert "not_home" in v["reasons"] and v["home_prompt"] is True and v["adjustments"] == []


def test_outcome_and_learning(built, tmp_path):
    p, sc = built("typical_week", tmp_path, raw=False)
    conn = db.connect(str(p))
    # Plans for the past 8 evenings, then mornings after each.
    for k in range(8, 0, -1):
        evening = sc["now"] - k * 86400
        run(p, sc, now=evening, tasks=("wind_down",))
        run(p, sc, now=evening + 14 * 3600, tasks=("wind_down_outcome",))
    outs = plans(conn, "wind_down_outcome")
    assert len(outs) == 8
    v = outs[-1][0]
    assert set(v) == {"night_of", "planned_wind_down_start", "planned_in_bed", "planned_onset", "actual_in_bed",
                      "actual_onset", "actual_wake", "latency", "asleep_min", "followed"}
    assert all(isinstance(o[0]["followed"], bool) for o in outs)
    # Synthetic latencies are 8–25 min → mean between 10 and 30 → length unchanged.
    assert db.get_state(conn, W.LEN_KEY) == "60.0"
    # Idempotent: a second morning run adds nothing.
    assert run(p, sc, now=sc["now"] + 14 * 3600 - 86400, tasks=("wind_down_outcome",))["tasks"]["wind_down_outcome"]["rows_written"] == 0


@pytest.mark.parametrize("lat,expected", [(40, "75.0"), (5, "45.0")])
def test_length_adapts_to_latency(tmp_path, lat, expected):
    p = tmp_path / "w.sqlite"
    conn = db.create(str(p))
    base = datetime(2026, 10, 1, 23, 0, tzinfo=NY).timestamp()
    for k in range(7):
        t = base + k * 86400
        conn.execute("INSERT INTO processed_samples (hk_uuid, hk_type, label, value, value_text, start_ts, end_ts, minute_id,"
                     " inserted_at) VALUES (?, 'S', 'sleep_analysis', 0, 'in_bed', ?, ?, 0, 0)", (f"b{k}", t, t + 8 * 3600))
        conn.execute("INSERT INTO processed_samples (hk_uuid, hk_type, label, value, value_text, start_ts, end_ts, minute_id,"
                     " inserted_at) VALUES (?, 'S', 'sleep_analysis', 3, 'asleep_core', ?, ?, 0, 0)",
                     (f"a{k}", t + lat * 60, t + 8 * 3600))
        night = datetime.fromtimestamp(t, NY).date().isoformat()
        conn.execute("INSERT INTO inferences (kind, minute_start, minute_end, value_json, algorithm, algorithm_version,"
                     " computed_at, computed_where) VALUES ('wind_down_plan', ?, ?, ?, 'wind_down', 'wind_down-v1', 0, 'phone')",
                     (int((t - 5400) // 60), int((t + 8 * 3600) // 60),
                      json.dumps({"night_of": night, "wind_down_start": "21:30", "target_in_bed": "23:00",
                                  "target_sleep_onset": "23:15", "wind_down_len_min": 60})))
    db.set_state(conn, W.LEN_KEY, "60.0")
    fengshui_engine.run(str(p), now_ts=base + 7 * 86400 + 12 * 3600, tz="America/New_York", where="phone",
                        tasks=["wind_down_outcome"])
    assert db.get_state(conn, W.LEN_KEY) == expected
