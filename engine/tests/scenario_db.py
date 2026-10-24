"""Build a v1 database from a synthetic scenario, the way the phone would fill it.

Mirrors the Swift collection code (HealthSync, VisitRecorder, MotionImporter,
WatchImporter) closely enough that the engine sees the same tables on the Mac
and on the phone. Used by engine tests and the phone/server parity checks.
"""

from __future__ import annotations

import json
import math
from pathlib import Path

import synth
from fengshui_engine import db
from fengshui_engine.hk_labels import label_for_identifier
from fengshui_engine.minute import minute_id
from fengshui_engine.places import haversine_m
from fengshui_engine.raw import ENCODING, SENSOR_AXES, SENSOR_SCALE


def match_place(places: list[dict], lat: float, lon: float) -> int | None:
    """Nearest place whose radius contains the point (same rule as Swift PlaceMatcher)."""
    best, best_d = None, math.inf
    for p in places:
        d = haversine_m(lat, lon, p["lat"], p["lon"])
        if d <= p["radius_m"] and d < best_d:
            best, best_d = p["id"], d
    return best


def build(path: str | Path, scenario: dict | str, *, raw: bool = False, places: bool = True):
    sc = synth.load(scenario) if isinstance(scenario, str) else scenario
    conn = db.create(str(path))
    now = sc["now"]
    conn.execute("BEGIN")
    rows = []
    for r in sc["samples"]:
        uuid, t, v, vt, unit, s, e, src, bundle, dev, meta = r
        rows.append((uuid, t, label_for_identifier(t), v, vt, unit, s, e, minute_id(s), src, bundle, dev,
                     json.dumps(meta, sort_keys=True, separators=(",", ":")) if meta else None, now))
    for w in sc["workouts"]:
        rows.append((w["uuid"], "HKWorkoutTypeIdentifier", "workout", w["end"] - w["start"], w["activity"], "s",
                     w["start"], w["end"], minute_id(w["start"]), w["source"], None, None,
                     json.dumps({"distance_m": w["distance_m"], "energy_kcal": w["energy_kcal"]}, sort_keys=True,
                                separators=(",", ":")), now))
        conn.executemany("INSERT INTO processed_route_points (workout_uuid, ts, minute_id, lat, lon, alt_m, speed_mps,"
                         " h_accuracy) VALUES (?,?,?,?,?,?,?,?)",
                         [(w["uuid"], p[0], minute_id(p[0]), *p[1:]) for p in w["route"]])
    conn.executemany("INSERT INTO processed_samples (hk_uuid, hk_type, label, value, value_text, unit, start_ts, end_ts,"
                     " minute_id, source_name, source_bundle, device, metadata_json, inserted_at)"
                     " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", rows)
    conn.executemany("INSERT INTO characteristics (key, value) VALUES (?, ?)", sc["characteristics"].items())
    conn.executemany("INSERT OR IGNORE INTO context_motion (start_ts, end_ts, minute_id, activity, confidence)"
                     " VALUES (?,?,?,?,?)", [(m[0], m[1], minute_id(m[0]), m[2], m[3]) for m in sc["motion"]])
    plist = []
    if places:
        for p in sc["places"]:
            cur = conn.execute("INSERT INTO context_places (name, kind, lat, lon, radius_m, confirmed, created_at)"
                               " VALUES (?,?,?,?,?,1,?)", (p["name"], p["kind"], p["lat"], p["lon"], p["radius_m"],
                                                           sc["now"] - sc["days"] * 86400))
            plist.append({**p, "id": cur.lastrowid})
    for a, d, lat, lon, acc in sc["visits"]:
        conn.execute("INSERT INTO context_visits (place_id, lat, lon, h_accuracy, arrival_ts, departure_ts,"
                     " minute_start, minute_end) VALUES (?,?,?,?,?,?,?,?)",
                     (match_place(plist, lat, lon), lat, lon, acc, a, d, minute_id(a),
                      minute_id(d) if d is not None else None))
    prefs = {"time_zone": sc["tz"], "onboarding_sleep": sc["onboarding"]}
    conn.executemany("INSERT INTO preferences (key, value_json, updated_at) VALUES (?,?,?)",
                     [(k, json.dumps(v, sort_keys=True), now) for k, v in prefs.items()])
    if raw:
        conn.executemany(
            "INSERT OR REPLACE INTO raw_chunks (minute_id, sensor, tier, rate_hz, sample_count, axes, encoding, scale,"
            " offset, payload, received_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)",
            [(mid, sensor, tier, 50.0 if tier == 1 else 25.0, n, SENSOR_AXES[sensor], ENCODING,
              SENSOR_SCALE[sensor][0], SENSOR_SCALE[sensor][1], payload, now)
             for mid, sensor, tier, payload, n in synth.raw_chunks(sc)])
    conn.execute("COMMIT")
    return conn, sc
