import json
from datetime import datetime, timedelta
from types import SimpleNamespace
from zoneinfo import ZoneInfo

import scenario_db
import synth
from fengshui_server.deployment import TOOLS, DeploymentWatcher
from fengshui_server.store import Store


def ev(type_, **kw):
    return SimpleNamespace(type=type_, **kw)


class FakeClient:
    def __init__(self, history, stream):
        self.sent = []
        runs = [SimpleNamespace(id="drun_1", session_id="sesn_run", error=None),
                SimpleNamespace(id="drun_0", session_id=None, error=SimpleNamespace(type="environment_archived"))]
        events = SimpleNamespace(list=lambda sid, limit=None: iter(history), stream=lambda sid, timeout=None: iter(stream),
                                 send=lambda sid, events: self.sent.append(events[0]))
        self.beta = SimpleNamespace(deployment_runs=SimpleNamespace(list=lambda **kw: iter(runs)),
                                    sessions=SimpleNamespace(events=events))


def setup(tmp_path, history, stream):
    sc = synth.load("typical_week")
    (tmp_path / "data").mkdir()
    conn, _ = scenario_db.build(tmp_path / "data" / "server.sqlite", sc)
    conn.execute("CREATE TABLE IF NOT EXISTS devices (device_id TEXT PRIMARY KEY, name TEXT, engine_version TEXT, last_seen REAL NOT NULL)")
    conn.execute("INSERT INTO devices VALUES ('phone-1', 'iPhone', '0.1.0', 1)")
    conn.commit()
    conn.close()
    store = Store(tmp_path / "data")
    from fengshui_server import monitor as mon
    mon.Monitor(store)                                   # creates the alert tables, as the app does
    client = FakeClient(history, stream)
    w = DeploymentWatcher(client, "depl_x", store, clock=lambda: sc["now"], tz=sc["tz"])
    today = datetime.fromtimestamp(sc["now"], ZoneInfo(sc["tz"])).date()
    return w, client, store, today


def test_serves_pending_and_new_tool_calls_and_files_the_message(tmp_path):
    today = None
    sc = synth.load("typical_week")
    day = datetime.fromtimestamp(sc["now"], ZoneInfo(sc["tz"])).date()
    week = (day - timedelta(days=6)).isoformat()
    history = [ev("user.message"), ev("agent.custom_tool_use", id="sevt_1", name="list_available_data", input={})]
    stream = [ev("agent.custom_tool_use", id="sevt_1", name="list_available_data", input={}),   # replayed: skip
              ev("agent.custom_tool_use", id="sevt_2", name="get_sleep_nights", input={"start": week, "end": day.isoformat()}),
              ev("agent.custom_tool_use", id="sevt_3", name="create_report", input={}),
              ev("agent.custom_tool_use", id="sevt_4", name="notify_user",
                 input={"title": "Weekly check-in", "body": "You averaged 7 h sleep.", "severity": "info"}),
              ev("agent.message", content=[SimpleNamespace(type="text", text="Sent.")]),
              ev("session.status_idle", stop_reason=SimpleNamespace(type="end_turn"))]
    w, client, store, today = setup(tmp_path, history, stream)
    assert w.tick(wait=True) == ["sesn_run"]                 # the failed run without a session is skipped
    ids = [e["custom_tool_use_id"] for e in client.sent]
    assert ids == ["sevt_1", "sevt_2", "sevt_3", "sevt_4"]
    assert "heart_rate" in client.sent[0]["content"][0]["text"]
    assert json.loads(client.sent[1]["content"][0]["text"])["nights"]
    assert client.sent[2]["is_error"] is True                # phone-only tool
    conn = store.connect()
    alert = [tuple(r) for r in conn.execute("SELECT device_id, title, decided_by FROM monitor_alerts")]
    run = conn.execute("SELECT status, tool_calls FROM agent_runs WHERE run_id='drun_1'").fetchone()
    conn.close()
    assert alert == [("phone-1", "Weekly check-in", "deployment")]
    assert tuple(run) == ("done", 4)
    assert w.tick(wait=True) == []                           # not served twice


def test_final_message_reaches_inbox_without_notify(tmp_path):
    stream = [ev("agent.message", content=[SimpleNamespace(type="text", text="All readings look normal today.")]),
              ev("session.status_idle", stop_reason=SimpleNamespace(type="end_turn"))]
    w, client, store, _ = setup(tmp_path, [], stream)
    w.tick(wait=True)
    conn = store.connect()
    rows = [tuple(r) for r in conn.execute("SELECT title, body FROM monitor_alerts")]
    conn.close()
    assert rows == [("Scheduled check-in", "All readings look normal today.")]


def test_tool_definitions_are_custom_and_strict_schemas():
    assert {t["type"] for t in TOOLS} == {"custom"}
    assert all(t["input_schema"]["additionalProperties"] is False for t in TOOLS)
    assert "notify_user" in {t["name"] for t in TOOLS}
