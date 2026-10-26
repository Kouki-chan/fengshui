import json
from datetime import datetime, timedelta
from zoneinfo import ZoneInfo

import pytest
from fastapi.testclient import TestClient

import scenario_db
import synth
from fengshui_server.app import Settings, create_app

TOKEN = "test-token-not-secret"
H = {"Authorization": f"Bearer {TOKEN}", "Accept": "application/json, text/event-stream",
     "Content-Type": "application/json"}


@pytest.fixture
def mcp(tmp_path, monkeypatch):
    sc = synth.load("typical_week")
    monkeypatch.setenv("FENGSHUI_TZ", sc["tz"])
    data = tmp_path / "data"
    data.mkdir()
    conn, _ = scenario_db.build(data / "server.sqlite", sc)
    conn.close()
    app = create_app(Settings(data_dir=data, token=TOKEN, diagnostics_dir=tmp_path / "diag"))
    with TestClient(app, base_url="http://localhost:8765") as c:
        ids = iter(range(1, 1000))

        def rpc(method, params=None, headers=H):
            r = c.post("/mcp", headers=headers, json={"jsonrpc": "2.0", "id": next(ids), "method": method,
                                                      "params": params or {}})
            return r

        today = datetime.fromtimestamp(sc["now"], ZoneInfo(sc["tz"])).date()
        yield rpc, today


def call(rpc, name, args):
    r = rpc("tools/call", {"name": name, "arguments": args})
    assert r.status_code == 200, r.text
    res = r.json()["result"]
    assert not res.get("isError"), res
    return res.get("structuredContent") or json.loads(res["content"][0]["text"])


def test_requires_token(mcp):
    rpc, _ = mcp
    r = rpc("tools/list", headers={**H, "Authorization": "Bearer wrong"})
    assert r.status_code == 401


def test_initialize_and_list_tools(mcp):
    rpc, _ = mcp
    init = rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                              "clientInfo": {"name": "test", "version": "1"}})
    assert init.status_code == 200, init.text
    assert init.json()["result"]["serverInfo"]["name"] == "Fengshui"
    tools = {t["name"]: t for t in rpc("tools/list").json()["result"]["tools"]}
    assert set(tools) == {"list_available_data", "get_series", "get_sleep_nights", "get_inferences", "get_visits",
                          "list_report_labels", "get_monitor_status"}
    assert all(t["annotations"]["readOnlyHint"] for t in tools.values())


def test_tools_return_processed_data_only(mcp):
    rpc, today = mcp
    week = (today - timedelta(days=6)).isoformat()
    avail = call(rpc, "list_available_data", {})
    labels = {l["label"]: l for l in avail["labels"]}
    assert {"heart_rate", "step_count", "sleep_analysis"} <= set(labels)
    assert labels["heart_rate"]["group"] == "Vitals"
    hr = call(rpc, "get_series", {"label": "heart_rate", "start": week, "end": today.isoformat(), "bucket": "1d",
                                  "agg": "avg"})
    assert hr["unit"] == "bpm" and 40 < hr["points"][0][1] < 150
    nights = call(rpc, "get_sleep_nights", {"start": week, "end": today.isoformat()})["nights"]
    assert len(nights) >= 5 and all(n["asleep_min"] > 0 for n in nights)
    groups = call(rpc, "list_report_labels", {"start": week, "end": today.isoformat()})["groups"]
    assert "Sleep" in groups and "Activity" in groups
    assert call(rpc, "get_monitor_status", {}) == {"session": None, "alerts": []}
    blob = json.dumps([avail, hr, nights, groups])
    for raw in ("raw_chunks", "raw_minute_features", "payload", "enmo_mg", "lat", "lon"):
        assert f'"{raw}"' not in blob, raw


def test_bad_arguments_are_tool_errors(mcp):
    rpc, today = mcp
    r = rpc("tools/call", {"name": "get_series", "arguments": {"label": "heart_rate", "start": "2026-13-01",
                                                               "end": today.isoformat()}})
    assert r.json()["result"]["isError"] is True


def test_read_only_guard():
    from fengshui_server.mcp_server import Data
    d = Data(":memory:", "UTC")
    with pytest.raises(ValueError, match="raw watch data"):
        d.rows("SELECT payload FROM raw_chunks")
