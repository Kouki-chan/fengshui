"""Canonical dumps of engine output, used for phone/Mac/server parity checks and by
the server's /compute response. Ids and timestamps of the run itself are excluded
because they legitimately differ between machines."""

from __future__ import annotations

import hashlib
import json
import sqlite3

INFERENCE_COLS = ["kind", "minute_start", "minute_end", "value_json", "confidence", "algorithm",
                  "algorithm_version", "provisional"]


def inference_rows(conn: sqlite3.Connection, *, live_only: bool = True) -> list[list]:
    q = f"SELECT {', '.join(INFERENCE_COLS)}, superseded_by IS NOT NULL FROM inferences" + \
        (" WHERE superseded_by IS NULL" if live_only else "") + " ORDER BY kind, minute_start, minute_end, value_json"
    return [list(r) for r in conn.execute(q)]


def features_digest(conn: sqlite3.Connection) -> str:
    h = hashlib.sha256()
    for r in conn.execute("SELECT minute_id, accel_samples, enmo_mg, mag_sd_mg, cadence_hz, active_frac, pressure_kpa,"
                          " vert_speed_m_min, heading_change_deg, gyro_rms_dps, feature_version "
                          "FROM raw_minute_features ORDER BY minute_id"):
        h.update(json.dumps(list(r)).encode())
    return h.hexdigest()


def canonical(db_path: str) -> str:
    conn = sqlite3.connect(db_path)
    try:
        return json.dumps({"inferences": inference_rows(conn), "features_sha256": features_digest(conn),
                           "engine_state": sorted(conn.execute("SELECT key, value FROM engine_state").fetchall())},
                          separators=(",", ":"))
    finally:
        conn.close()
