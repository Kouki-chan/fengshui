import base64
import hashlib
import json
import shutil
import sqlite3

import pytest
from fastapi.testclient import TestClient

import fengshui_engine
import scenario_db
from fengshui_engine import ENGINE_VERSION
from fengshui_engine.dump import inference_rows
from fengshui_server.app import Settings, create_app

TOKEN = "test-token-not-secret"
H = {"Authorization": f"Bearer {TOKEN}"}
SYNC_TABLES = ["processed_samples", "processed_route_points", "characteristics", "context_motion", "context_places",
               "context_visits", "context_screen_events", "preferences", "raw_chunks", "engine_state", "inferences"]


@pytest.fixture
def client(tmp_path):
    s = Settings(data_dir=tmp_path / "data", token=TOKEN, diagnostics_dir=tmp_path / "diag")
    return TestClient(create_app(s))


def table_rows(conn, table):
    conn.row_factory = sqlite3.Row
    out = []
    for r in conn.execute(f"SELECT * FROM {table}"):
        d = dict(r)
        if isinstance(d.get("payload"), bytes):
            d["payload_b64"] = base64.b64encode(d.pop("payload")).decode()
        out.append(d)
    return out


def sync_all(client, conn, tables=SYNC_TABLES):
    body = {"device_id": "phone-1", "device_name": "test", "engine_version": ENGINE_VERSION,
            "tables": {t: table_rows(conn, t) for t in tables}}
    r = client.post("/sync", headers=H, json=body)
    assert r.status_code == 200, r.text
    return r.json()


def test_health_needs_no_auth(client):
    r = client.get("/health")
    assert r.json()["ok"] and r.json()["engine_version"] == ENGINE_VERSION


@pytest.mark.parametrize("hdr", [{}, {"Authorization": "Bearer nope"}, {"Authorization": TOKEN}])
def test_auth_required(client, hdr):
    for path, body in [("/sync", {"device_id": "x", "engine_version": ENGINE_VERSION}),
                       ("/raw/archive", {"chunks": []}), ("/diagnostics", {})]:
        assert client.post(path, headers=hdr, json=body).status_code == 401
    assert client.get("/raw?sensor=accel&from_minute=0&to_minute=1", headers=hdr).status_code == 401


def test_engine_version_mismatch_rejected(client):
    r = client.post("/sync", headers=H, json={"device_id": "x", "engine_version": "0.0.0"})
    assert r.status_code == 409
    r = client.post("/compute", headers=H, json={"engine_version": "9.9", "now_ts": 0, "tz": "UTC"})
    assert r.status_code == 409


def test_unknown_table_rejected(client):
    r = client.post("/sync", headers=H, json={"device_id": "x", "engine_version": ENGINE_VERSION,
                                              "tables": {"sqlite_master": []}})
    assert r.status_code == 400


def test_sync_idempotent(client, tmp_path):
    conn, _ = scenario_db.build(tmp_path / "phone.sqlite", "no_watch_data")
    a = sync_all(client, conn)
    srv = sqlite3.connect(client.app.state.store.db_path)
    counts = {t: srv.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] for t in SYNC_TABLES}
    b = sync_all(client, conn)
    assert a["accepted"] == b["accepted"]
    assert counts == {t: srv.execute(f"SELECT COUNT(*) FROM {t}").fetchone()[0] for t in SYNC_TABLES}
    assert counts["processed_samples"] == conn.execute("SELECT COUNT(*) FROM processed_samples").fetchone()[0]
    assert srv.execute("SELECT COUNT(*) FROM devices").fetchone()[0] == 1


def test_sync_deletions_and_export_adoption(client, tmp_path):
    srv = sqlite3.connect(client.app.state.store.db_path)
    srv.execute("INSERT INTO processed_samples (hk_uuid, hk_type, label, value, unit, start_ts, end_ts, minute_id,"
                " source_name, inserted_at) VALUES ('export:abc','HKQuantityTypeIdentifierHeartRate','heart_rate',"
                " 62, 'count/min', 1000, 1000, 16, 'Watch', 0)")
    srv.commit()
    row = {"hk_uuid": "REAL-UUID", "hk_type": "HKQuantityTypeIdentifierHeartRate", "label": "heart_rate", "value": 62.0,
           "unit": "count/min", "start_ts": 1000.3, "end_ts": 1000.3, "minute_id": 16, "source_name": "Watch",
           "deleted": 0, "inserted_at": 5}
    body = {"device_id": "p", "engine_version": ENGINE_VERSION, "tables": {"processed_samples": [row]}}
    assert client.post("/sync", headers=H, json=body).status_code == 200
    assert srv.execute("SELECT hk_uuid FROM processed_samples").fetchall() == [("REAL-UUID",)]
    body["deleted_uuids"] = ["REAL-UUID"]
    body["tables"] = {}
    client.post("/sync", headers=H, json=body)
    assert srv.execute("SELECT deleted FROM processed_samples").fetchone()[0] == 1


def test_archive_retrieval_is_byte_exact(client, tmp_path):
    conn, _ = scenario_db.build(tmp_path / "phone.sqlite", "sparse_data", raw=True)
    rows = conn.execute("SELECT minute_id, sensor, tier, rate_hz, sample_count, axes, encoding, scale, offset, payload "
                        "FROM raw_chunks WHERE sensor='accel' ORDER BY minute_id LIMIT 120").fetchall()
    chunks = [{"minute_id": r[0], "sensor": r[1], "tier": r[2], "rate_hz": r[3], "sample_count": r[4], "axes": r[5],
               "encoding": r[6], "scale": r[7], "offset": r[8], "payload_b64": base64.b64encode(r[9]).decode()}
              for r in rows]
    res = client.post("/raw/archive", headers=H, json={"chunks": chunks}).json()["archived"]
    assert len(res) == 120 and all(x["archive_ref"].endswith(".fsr1") for x in res)
    # Partitioned by UTC day, stored unchanged.
    store = client.app.state.store
    assert (store.raw_dir / res[0]["archive_ref"]).read_bytes() == rows[0][9]
    # Re-archiving is idempotent.
    assert client.post("/raw/archive", headers=H, json={"chunks": chunks[:3]}).status_code == 200
    got = client.get(f"/raw?sensor=accel&from_minute={rows[0][0]}&to_minute={rows[-1][0]}", headers=H).json()["chunks"]
    assert len(got) == 120
    for g, r in zip(got, rows):
        blob = base64.b64decode(g["payload_b64"])
        assert blob == r[9] and g["sha256"] == hashlib.sha256(r[9]).hexdigest()
        assert g["minute_id"] == r[0] and g["archive_ref"]
    assert client.get("/raw?sensor=gyro&from_minute=0&to_minute=1", headers=H).json()["chunks"] == []


def test_compute_parity_with_phone(client, tmp_path):
    """Server results equal phone results for the same scenario (spec §14.2 Phase 6)."""
    phone = tmp_path / "phone.sqlite"
    conn, sc = scenario_db.build(phone, "typical_week", raw=True)
    conn.close()
    other = tmp_path / "phone_local.sqlite"
    shutil.copy(phone, other)
    tasks = ["features", "activity", "wind_down_outcome", "wind_down", "place_suggestions"]
    fengshui_engine.run(str(other), now_ts=sc["now"], tz=sc["tz"], where="phone", tasks=tasks)
    conn = sqlite3.connect(phone)
    sync_all(client, conn)
    r = client.post("/compute", headers=H, json={"engine_version": ENGINE_VERSION, "since_id": 0, "now_ts": sc["now"],
                                                 "tz": sc["tz"], "tasks": tasks})
    assert r.status_code == 200, r.text
    out = r.json()
    assert all(x["computed_where"] == "server" for x in out["inferences"])
    srv = sqlite3.connect(client.app.state.store.db_path)
    local = sqlite3.connect(other)
    assert inference_rows(srv) == inference_rows(local)
    assert len(out["raw_minute_features"]) == local.execute("SELECT COUNT(*) FROM raw_minute_features").fetchone()[0]
    assert out["engine_state"] == dict(local.execute("SELECT key, value FROM engine_state").fetchall())
    # A second compute with nothing new returns no new rows.
    max_id = max(x["id"] for x in out["inferences"])
    r2 = client.post("/compute", headers=H, json={"engine_version": ENGINE_VERSION, "since_id": max_id,
                                                  "now_ts": sc["now"], "tz": sc["tz"], "tasks": tasks}).json()
    assert r2["inferences"] == []


def test_diagnostics_stored_and_readable(client, tmp_path):
    rep = {"checks": [{"name": "healthkit", "ok": True}], "app_version": "0.1.0"}
    r = client.post("/diagnostics", headers=H, json=rep)
    assert r.status_code == 200
    assert (tmp_path / "diag" / r.json()["stored"]).exists()
    assert client.get("/diagnostics/latest", headers=H).json() == rep
