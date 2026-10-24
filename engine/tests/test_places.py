import json

import fengshui_engine
import scenario_db
import synth
from fengshui_engine import config as C
from fengshui_engine.places import cluster, haversine_m


def test_haversine():
    assert haversine_m(40.0, -75.0, 40.0, -75.0) == 0
    # 0.001° latitude ≈ 111 m
    assert 110 < haversine_m(40.0, -75.0, 40.001, -75.0) < 112


def test_cluster_groups_within_radius():
    pts = [(40.0, -75.0), (40.0005, -75.0), (40.1, -75.1), (40.0003, -75.0004), (40.1004, -75.1)]
    groups = sorted(sorted(g) for g in cluster(pts, 150))
    assert groups == [[0, 1, 3], [2, 4]]


def test_visit_matching_nearest_place_within_radius():
    places = [{"id": 1, "lat": 40.0, "lon": -75.0, "radius_m": 150},
              {"id": 2, "lat": 40.0012, "lon": -75.0, "radius_m": 150}]
    assert scenario_db.match_place(places, 40.0001, -75.0) == 1
    assert scenario_db.match_place(places, 40.0011, -75.0) == 2      # nearer to 2, inside both
    assert scenario_db.match_place(places, 40.01, -75.0) is None


def run_suggest(conn_path, now):
    return fengshui_engine.run(str(conn_path), now_ts=now, tz="America/New_York", where="phone",
                               tasks=["place_suggestions"])


def test_typical_week_suggests_gym_and_cafe(tmp_path):
    p = tmp_path / "t.sqlite"
    conn, sc = scenario_db.build(p, "typical_week")
    s = run_suggest(p, sc["now"])
    assert s["tasks"]["place_suggestions"]["rows_written"] == 2
    rows = conn.execute("SELECT lat, lon, confirmed, radius_m FROM context_places WHERE kind='suggested'").fetchall()
    assert all(r[2] == 0 and r[3] == C.PLACE_DEFAULT_RADIUS_M for r in rows)
    near = lambda lat, lon: any(haversine_m(r[0], r[1], lat, lon) < 50 for r in rows)  # noqa: E731
    assert near(*synth.GYM) and near(*synth.CAFE)


def test_suggestions_are_idempotent_and_respect_dismissals(tmp_path):
    p = tmp_path / "t.sqlite"
    conn, sc = scenario_db.build(p, "typical_week")
    run_suggest(p, sc["now"])
    assert run_suggest(p, sc["now"])["tasks"]["place_suggestions"]["rows_written"] == 0
    # The user dismisses the gym suggestion: the app deletes it and remembers the spot.
    conn.execute("DELETE FROM context_places WHERE kind='suggested' AND abs(lat - ?) < 0.001", (synth.GYM[0],))
    conn.execute("INSERT INTO preferences (key, value_json, updated_at) VALUES ('dismissed_places', ?, 0)",
                 (json.dumps([list(synth.GYM)]),))
    assert run_suggest(p, sc["now"])["tasks"]["place_suggestions"]["rows_written"] == 0


def test_needs_three_visits(tmp_path):
    p = tmp_path / "t.sqlite"
    conn, sc = scenario_db.build(p, "new_user")
    for i in range(2):
        conn.execute("INSERT INTO context_visits (lat, lon, arrival_ts, departure_ts, minute_start) "
                     "VALUES (40.3, -75.3, ?, ?, 0)", (sc["now"] - 86400 * (i + 1), sc["now"] - 86400 * (i + 1) + 3600))
    assert run_suggest(p, sc["now"])["tasks"]["place_suggestions"]["rows_written"] == 0
    conn.execute("INSERT INTO context_visits (lat, lon, arrival_ts, departure_ts, minute_start) "
                 "VALUES (40.3001, -75.3, ?, ?, 0)", (sc["now"] - 3600 * 5, sc["now"] - 3600 * 4))
    assert run_suggest(p, sc["now"])["tasks"]["place_suggestions"]["rows_written"] == 1


def test_short_pass_through_visits_ignored(tmp_path):
    p = tmp_path / "t.sqlite"
    conn, sc = scenario_db.build(p, "new_user")
    for i in range(4):
        t = sc["now"] - 86400 * (i + 1)
        conn.execute("INSERT INTO context_visits (lat, lon, arrival_ts, departure_ts, minute_start) "
                     "VALUES (40.3, -75.3, ?, ?, 0)", (t, t + 120))
    assert run_suggest(p, sc["now"])["tasks"]["place_suggestions"]["rows_written"] == 0
