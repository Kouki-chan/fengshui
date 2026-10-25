import random

import pytest

import fengshui_engine
import synth
from fengshui_engine import config as C
from fengshui_engine import db, features, raw


def chunk_for(kind, seed=1, t0=0.0):
    v = synth.accel_minute(kind, t0, random.Random(seed))
    return raw.RawChunk("accel", t0, 50.0, raw.quantize("accel", v))


@pytest.mark.parametrize("kind,lo,hi", [("walk", 1.7, 2.0), ("stairs", 1.5, 1.7), ("run", 2.6, 2.9), ("cycle", 1.2, 1.4)])
def test_cadence(kind, lo, hi):
    f = features.accel_features(chunk_for(kind))
    assert lo <= f["cadence_hz"] <= hi


@pytest.mark.parametrize("kind", ["off", "sleep", "still", "desk"])
def test_still_minutes_have_no_cadence_and_low_enmo(kind):
    f = features.accel_features(chunk_for(kind))
    assert f["cadence_hz"] is None
    assert f["enmo_mg"] < C.ENMO_LIGHT_MG and f["active_frac"] == 0
    if kind == "off":
        assert f["mag_sd_mg"] < C.WATCH_OFF_SD_MG


def test_enmo_ordering_and_active_frac():
    e = {k: features.accel_features(chunk_for(k)) for k in ["still", "light", "walk", "run"]}
    assert e["still"]["enmo_mg"] < e["light"]["enmo_mg"] < e["walk"]["enmo_mg"] < e["run"]["enmo_mg"]
    assert e["walk"]["active_frac"] == 1.0 and e["run"]["enmo_mg"] > C.RUN_ENMO_MG


def test_enmo_definition_exact():
    # |a| = 1.25 g for every sample → ENMO 250 mg, SD 0.
    c = raw.RawChunk("accel", 0, 50.0, raw.quantize("accel", [(0.75, 0.0, -1.0)] * 3000))
    f = features.accel_features(c)
    assert f["enmo_mg"] == pytest.approx(250, abs=0.5)
    assert f["mag_sd_mg"] == pytest.approx(0, abs=0.01)
    assert f["cadence_hz"] is None


def test_cadence_null_when_peak_below_threshold():
    rnd = random.Random(5)
    noise = [(rnd.gauss(0, .2), rnd.gauss(0, .2), -1 + rnd.gauss(0, .2)) for _ in range(3000)]
    assert features.cadence_hz([(x * x + y * y + z * z) ** .5 for x, y, z in noise], 50.0) is None


def _insert(conn, mid, sensor, tier, rate, values, received):
    c = raw.RawChunk(sensor, mid * 60.0, rate, raw.quantize(sensor, values))
    conn.execute("INSERT OR REPLACE INTO raw_chunks (minute_id, sensor, tier, rate_hz, sample_count, axes, encoding,"
                 " scale, offset, payload, received_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
                 (mid, sensor, tier, rate, len(values), raw.SENSOR_AXES[sensor], raw.ENCODING,
                  *raw.SENSOR_SCALE[sensor], raw.encode(c), received))


def run(path, now, tasks=("features",)):
    return fengshui_engine.run(str(path), now_ts=now, tz="UTC", where="phone", tasks=list(tasks))


def test_snapshot_features_baro_compass_gyro(tmp_path):
    p = tmp_path / "f.sqlite"
    conn = db.create(str(p))
    mid = 29_880_000
    # Climbing: pressure drops 0.012 kPa/min ≈ 1 m/min... use 0.05 kPa over 5 s ≈ 50 m/min.
    _insert(conn, mid, "baro", 2, 25.0, [(101.3 - 0.0004 * i,) for i in range(125)], 1.0)
    _insert(conn, mid, "compass", 2, 25.0, [((350 + 2 * i) % 360,) for i in range(125)], 1.0)
    _insert(conn, mid, "gyro", 2, 25.0, [(0.5, 0.0, 0.0)] * 125, 1.0)
    run(p, 10.0)
    r = conn.execute("SELECT * FROM raw_minute_features WHERE minute_id=?", (mid,)).fetchone()
    assert r["accel_samples"] is None
    assert r["pressure_kpa"] == pytest.approx(101.3 - 0.0004 * 62, abs=1e-3)
    # −0.0004 kPa per 1/25 s = −0.01 kPa/s = −0.1 hPa/s → +0.83 m/s → +49.8 m/min
    assert r["vert_speed_m_min"] == pytest.approx(0.0004 * 25 * 10 * C.BARO_M_PER_HPA * 60, rel=0.02)
    assert r["heading_change_deg"] == pytest.approx(2 * 124, abs=0.5)        # wraps through 360 correctly
    assert r["gyro_rms_dps"] == pytest.approx(28.648, abs=0.01)
    assert r["feature_version"] == C.FEATURE_VERSION


def test_incremental_and_late_chunks(tmp_path):
    p = tmp_path / "f.sqlite"
    conn = db.create(str(p))
    mid = 29_880_000
    _insert(conn, mid, "accel", 1, 50.0, synth.accel_minute("walk", 0, random.Random(1)), 1.0)
    assert run(p, 10.0)["tasks"]["features"]["rows_written"] == 1
    assert run(p, 11.0)["tasks"]["features"]["rows_written"] == 0           # nothing new
    # A snapshot for the same minute arrives later → that minute is recomputed.
    _insert(conn, mid, "baro", 2, 25.0, [(101.3,)] * 125, 20.0)
    assert run(p, 30.0)["tasks"]["features"]["rows_written"] == 1
    r = conn.execute("SELECT cadence_hz, pressure_kpa FROM raw_minute_features").fetchone()
    assert r[0] is not None and r[1] == pytest.approx(101.3)


def test_tier3_accel_used_when_no_tier1(tmp_path):
    p = tmp_path / "f.sqlite"
    conn = db.create(str(p))
    _insert(conn, 5, "accel", 3, 50.0, synth.accel_minute("run", 0, random.Random(2)), 1.0)
    run(p, 10.0)
    assert conn.execute("SELECT cadence_hz FROM raw_minute_features").fetchone()[0] > C.RUN_CADENCE_HZ


def test_archived_payloads_skipped(tmp_path):
    p = tmp_path / "f.sqlite"
    conn = db.create(str(p))
    _insert(conn, 5, "accel", 1, 50.0, synth.accel_minute("walk", 0, random.Random(2)), 1.0)
    conn.execute("UPDATE raw_chunks SET payload = NULL, archive_ref = 'x'")
    assert run(p, 10.0)["tasks"]["features"]["rows_written"] == 0


def test_scenario_features_one_row_per_raw_minute(built, tmp_path):
    p, sc = built("typical_week", tmp_path)
    s = run(p, sc["now"])
    conn = db.connect(str(p))
    n_minutes = conn.execute("SELECT COUNT(DISTINCT minute_id) FROM raw_chunks").fetchone()[0]
    assert s["tasks"]["features"]["rows_written"] == n_minutes
    print(f"METRIC mac_features_seconds={s['tasks']['features']['seconds']} minutes={n_minutes}")
