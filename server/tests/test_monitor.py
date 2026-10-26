import json
from types import SimpleNamespace

import httpx
import jwt
import pytest
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec
from fastapi.testclient import TestClient

from fengshui_server import monitor as mon
from fengshui_server.apns import APNs, team_id_from_xcconfig
from fengshui_server.app import Settings, create_app
from fengshui_server.monitor_agent import MonitorAgent

TOKEN = "test-token-not-secret"
H = {"Authorization": f"Bearer {TOKEN}"}
T0 = 1_792_519_200.0


class Clock:
    def __init__(self, t=T0):
        self.t = t

    def __call__(self):
        return self.t


def hr(ts, v):
    return {"label": "heart_rate", "ts": ts, "value": v, "unit": "bpm"}


def steps(ts, v, minutes=1):
    return {"label": "step_count", "ts": ts, "end_ts": ts + minutes * 60, "value": v, "unit": "steps"}


# ---------------------------------------------------------------- rules

def test_high_heart_rate_at_rest_needs_to_be_sustained():
    base = {"resting_heart_rate": 60}
    short = [hr(T0 + i * 60, 125) for i in range(5)]
    assert mon.evaluate(short, base) == []
    long = [hr(T0 + i * 60, 125) for i in range(12)]
    codes = [f.code for f in mon.evaluate(long, base)]
    assert codes == ["hr_rest_high"]


def test_high_heart_rate_during_activity_is_not_flagged():
    samples = [hr(T0 + i * 60, 140) for i in range(15)] + [steps(T0 + i * 60, 110) for i in range(15)]
    assert mon.evaluate(samples, {"resting_heart_rate": 60}) == []


def test_baseline_raises_the_threshold_for_high_resting_hr():
    samples = [hr(T0 + i * 60, 122) for i in range(12)]
    assert [f.code for f in mon.evaluate(samples, {"resting_heart_rate": 100})] == []   # limit is 130


def test_spo2_and_resp_and_apple_events():
    samples = [{"label": "oxygen_saturation", "ts": T0, "value": 86},
               {"label": "respiratory_rate", "ts": T0, "value": 30},
               {"label": "irregular_heart_rhythm_event", "ts": T0, "value": None, "text": "event"}]
    flags = {f.code: f.severity for f in mon.evaluate(samples, {})}
    assert flags == {"spo2_urgent": "urgent", "resp_out_of_range": "warning", "irregular_heart_rhythm_event": "warning"}


def test_single_low_spo2_is_info_two_are_warning():
    one = [{"label": "oxygen_saturation", "ts": T0, "value": 91}]
    two = one + [{"label": "oxygen_saturation", "ts": T0 + 600, "value": 90}]
    assert [f.severity for f in mon.evaluate(one, {})] == ["info"]
    assert [f.severity for f in mon.evaluate(two, {})] == ["warning"]


def test_hrv_drop_vs_baseline():
    s = [{"label": "heart_rate_variability_sdnn", "ts": T0, "value": 18}]
    assert [f.code for f in mon.evaluate(s, {"heart_rate_variability_sdnn": 50})] == ["hrv_drop"]
    assert mon.evaluate(s, {"heart_rate_variability_sdnn": 30}) == []


# ---------------------------------------------------------------- fake Claude

def block(type_, **kw):
    return SimpleNamespace(type=type_, **kw)


class FakeClaude:
    """Replays scripted responses and records each request."""

    def __init__(self, responses):
        self.responses = list(responses)
        self.requests = []
        self.messages = SimpleNamespace(create=self.create)

    def create(self, **kw):
        self.requests.append(json.loads(json.dumps(kw, default=lambda o: o.__dict__)))
        return self.responses.pop(0)


def tool_use(name, input_, id_="t1"):
    return SimpleNamespace(stop_reason="tool_use", content=[block("tool_use", id=id_, name=name, input=input_)])


@pytest.fixture
def env(tmp_path):
    clock = Clock()
    pushes = []

    class Push:
        def send(self, token, payload, *, background, env=None, collapse_id=None):
            pushes.append({"token": token, "payload": payload, "background": background})
            return 200, ""

    def make(agent=None, push=None):
        s = Settings(data_dir=tmp_path / "data", token=TOKEN, diagnostics_dir=tmp_path / "diag")
        app = create_app(s, monitor_agent=agent, push=push, clock=clock)
        return TestClient(app), app

    return SimpleNamespace(clock=clock, pushes=pushes, Push=Push, make=make)


def start(client, **kw):
    body = {"device_id": "phone-1", "interval_min": 5, "duration_h": 2, "push_token": "abc", **kw}
    r = client.post("/monitor/sessions", json=body, headers=H)
    assert r.status_code == 200, r.text
    return r.json()


def send(client, sid, samples, ts=T0, baselines=None):
    r = client.post("/monitor/readings", json={"session_id": sid, "ts": ts, "samples": samples,
                                               "baselines": baselines or {"resting_heart_rate": 60}}, headers=H)
    assert r.status_code == 200, r.text
    return r.json()


def test_session_validation_and_auth(env):
    c, _ = env.make()
    assert c.post("/monitor/sessions", json={"device_id": "x", "interval_min": 5, "duration_h": 1}).status_code == 401
    bad = c.post("/monitor/sessions", json={"device_id": "x", "interval_min": 0.5, "duration_h": 1}, headers=H)
    assert bad.status_code == 400
    bad = c.post("/monitor/sessions", json={"device_id": "x", "interval_min": 5, "duration_h": 30}, headers=H)
    assert bad.status_code == 400
    s = start(c)
    assert s["status"] == "active" and s["mode"] == "pull"          # no push configured
    assert c.get("/monitor/sessions/current", params={"device_id": "phone-1"}, headers=H).json()["session"]["id"] == s["id"]


def test_agent_called_only_on_flags_and_can_decline(env):
    claude = FakeClaude([tool_use("get_flags", {}), tool_use("no_alert", {"reason": "after exercise"}, "t2")])
    c, _ = env.make(agent=MonitorAgent(claude))
    sid = start(c)["id"]
    assert send(c, sid, [hr(T0, 70)])["alerts"] == []
    assert claude.requests == []                                    # no flag → no Claude call
    out = send(c, sid, [hr(T0 + i * 60, 128) for i in range(12)], ts=T0 + 720)
    assert out["alerts"] == []
    assert len(claude.requests) == 2
    req = claude.requests[0]
    assert req["model"] == "claude-sonnet-5-5" and req["tool_choice"] == {"type": "auto"}
    assert "temperature" not in req and req["extra_body"] == {"fallbacks": "default"}
    # The tool result went back in the second request.
    assert claude.requests[1]["messages"][-1]["content"][0]["type"] == "tool_result"


def test_agent_alert_is_stored_pushed_and_listed(env):
    claude = FakeClaude([tool_use("get_recent_readings", {"label": "heart_rate", "minutes": 30}),
                         tool_use("send_alert", {"severity": "warning", "title": "High heart rate at rest",
                                                 "body": "Your heart rate has been above 120 for 11 min."}, "t2")])
    c, _ = env.make(agent=MonitorAgent(claude), push=env.Push())
    sid = start(c)["id"]
    out = send(c, sid, [hr(T0 + i * 60, 128) for i in range(12)], ts=T0 + 720)
    [a] = out["alerts"]
    assert a["title"] == "High heart rate at rest" and a["decided_by"] == "agent" and a["pushed"] == 1
    assert env.pushes[-1]["background"] is False and env.pushes[-1]["payload"]["fs"] == "monitor_alert"
    readings = json.loads(claude.requests[1]["messages"][-1]["content"][0]["content"])["readings"]
    assert len(readings) == 12
    listed = c.get("/monitor/alerts", params={"device_id": "phone-1"}, headers=H).json()["alerts"]
    assert [x["id"] for x in listed] == [a["id"]]
    # Same flag again inside the cooldown: no second alert, no second agent call.
    n = len(claude.requests)
    assert send(c, sid, [hr(T0 + 800 + i * 60, 128) for i in range(12)], ts=T0 + 1500)["alerts"] == []
    assert len(claude.requests) == n


def test_hard_rules_notify_even_if_agent_declines_or_fails(env):
    claude = FakeClaude([tool_use("no_alert", {"reason": "probably a bad reading"})])
    c, _ = env.make(agent=MonitorAgent(claude))
    sid = start(c)["id"]
    [a] = send(c, sid, [{"label": "oxygen_saturation", "ts": T0, "value": 85}])["alerts"]
    assert a["severity"] == "urgent" and "emergency" in a["body"]

    class Broken:
        messages = SimpleNamespace(create=lambda **kw: (_ for _ in ()).throw(RuntimeError("network")))
    c2, _ = env.make(agent=MonitorAgent(Broken()))
    sid2 = start(c2, device_id="phone-2")["id"]
    [b] = send(c2, sid2, [hr(T0 + i * 60, 128) for i in range(12)], ts=T0 + 720)["alerts"]
    assert b["decided_by"].startswith("rules (agent error")


def test_agent_cannot_downgrade_urgent(env):
    claude = FakeClaude([tool_use("send_alert", {"severity": "info", "title": "FYI", "body": "Low oxygen reading."})])
    c, _ = env.make(agent=MonitorAgent(claude))
    sid = start(c)["id"]
    [a] = send(c, sid, [{"label": "oxygen_saturation", "ts": T0, "value": 84}])["alerts"]
    assert a["severity"] == "urgent"


def test_tick_requests_at_interval_and_reports_gaps(env):
    c, app = env.make(push=env.Push())
    sid = start(c, interval_min=5, duration_h=1)["id"]
    m = app.state.monitor
    m.tick()
    assert env.pushes[-1]["background"] is True and env.pushes[-1]["payload"]["fs"] == "monitor_request"
    env.clock.t += 120
    m.tick()
    assert len(env.pushes) == 1                                      # not due yet
    env.clock.t += 200
    m.tick()
    assert len(env.pushes) == 2
    # Readings arrive in only 2 of the first 4 intervals (iOS throttled the rest).
    send(c, sid, [hr(T0 + 10, 70)], ts=T0 + 30)
    send(c, sid, [hr(T0 + 960, 70)], ts=T0 + 960)
    env.clock.t = T0 + 4 * 300 - 1
    st = c.get("/monitor/sessions/current", params={"device_id": "phone-1"}, headers=H).json()["session"]["stats"]
    assert (st["intervals"], st["intervals_with_data"], st["coverage"]) == (4, 2, 0.5)
    # The session ends with a summary alert.
    env.clock.t = T0 + 3600 + 1
    m.tick()
    s = c.get("/monitor/sessions/current", params={"device_id": "phone-1"}, headers=H).json()["session"]
    assert s["status"] == "ended"
    alerts = c.get("/monitor/alerts", params={"device_id": "phone-1"}, headers=H).json()["alerts"]
    assert alerts[-1]["title"] == "Health monitoring finished"


def test_new_session_replaces_active_one_and_stop(env):
    c, _ = env.make()
    a = start(c)["id"]
    b = start(c)["id"]
    conn = c.app.state.store.connect()
    assert mon.session_row(conn, a)["status"] == "stopped"
    conn.close()
    assert c.post(f"/monitor/sessions/{b}/stop", headers=H).json()["status"] == "stopped"


# ---------------------------------------------------------------- APNs

def p8():
    key = ec.generate_private_key(ec.SECP256R1())
    pem = key.private_bytes(serialization.Encoding.PEM, serialization.PrivateFormat.PKCS8,
                            serialization.NoEncryption()).decode()
    return key, pem


def test_apns_request_shape_and_token():
    key, pem = p8()
    seen = []

    def handler(req: httpx.Request):
        seen.append(req)
        return httpx.Response(200)

    apns = APNs(pem, "KEYID12345", "TEAMID1234", client=httpx.Client(transport=httpx.MockTransport(handler)),
                clock=lambda: T0)
    assert apns.send("devtoken", {"aps": {"content-available": 1}}, background=True) == (200, "")
    r = seen[0]
    assert str(r.url) == "https://api.sandbox.push.apple.com/3/device/devtoken"
    assert r.headers["apns-push-type"] == "background" and r.headers["apns-priority"] == "5"
    assert r.headers["apns-topic"] == "com.chevin.fengshui"
    tok = r.headers["authorization"].removeprefix("bearer ")
    assert jwt.get_unverified_header(tok)["kid"] == "KEYID12345"
    claims = jwt.decode(tok, key.public_key(), algorithms=["ES256"])
    assert claims == {"iss": "TEAMID1234", "iat": int(T0)}


def test_apns_error_reason_and_unconfigured(tmp_path):
    _, pem = p8()
    apns = APNs(pem, "K", "T", client=httpx.Client(transport=httpx.MockTransport(
        lambda r: httpx.Response(400, json={"reason": "BadDeviceToken"}))))
    assert apns.send("x", {}, background=False) == (400, "BadDeviceToken")
    assert APNs.from_settings({}, tmp_path / "none.xcconfig") is None
    xc = tmp_path / "Local.xcconfig"
    xc.write_text("// local\nDEVELOPMENT_TEAM = ABCDE12345\n")
    assert team_id_from_xcconfig(xc) == "ABCDE12345"


# ---------------------------------------------------------------- Managed Agent backend

class FakeManaged:
    """Fake client.beta: one scripted SSE stream per session; records sends."""

    def __init__(self, script):
        self.script, self.sent, self.created = script, [], []
        agent = SimpleNamespace(tools=[SimpleNamespace(model_dump=lambda exclude_none=True: {"type": "agent_toolset_20260401"}),
                                       SimpleNamespace(model_dump=lambda exclude_none=True: {"type": "custom", "name": "get_flags",
                                                                                             "input_schema": {}})])
        sessions = SimpleNamespace(
            retrieve=lambda sid: SimpleNamespace(environment_id="env_123"),
            create=lambda **kw: (self.created.append(kw), SimpleNamespace(id=f"sesn_{len(self.created)}"))[1],
            events=SimpleNamespace(stream=lambda sid, timeout=None: iter(self.script),
                                   send=lambda sid, events: self.sent.append((sid, events))))
        self.beta = SimpleNamespace(agents=SimpleNamespace(retrieve=lambda aid: agent), sessions=sessions)


def ev(type_, **kw):
    return SimpleNamespace(type=type_, **kw)


def test_managed_agent_runs_tools_locally_and_returns_decision(env):
    from fengshui_server.monitor_agent import ManagedMonitorAgent
    fake = FakeManaged([
        ev("session.status_running"),
        ev("agent.custom_tool_use", id="sevt_1", name="get_recent_readings", input={"label": "heart_rate", "minutes": 30}),
        ev("agent.custom_tool_use", id="sevt_2", name="send_alert",
           input={"severity": "warning", "title": "High heart rate at rest", "body": "Above 120 for 11 min."}),
    ])
    agent = ManagedMonitorAgent(fake, "agent_x", reference_session_id="sesn_ref")
    c, _ = env.make(agent=agent)
    sid = start(c)["id"]
    [a] = send(c, sid, [hr(T0 + i * 60, 128) for i in range(12)], ts=T0 + 720)["alerts"]
    assert a["title"] == "High heart rate at rest" and a["decided_by"] == "agent"
    [created] = fake.created
    assert created["environment_id"] == "env_123"                          # found via the reference session
    assert created["agent"]["type"] == "agent_with_overrides" and created["agent"]["id"] == "agent_x"
    names = [t.get("name") for t in created["agent"]["tools"]]
    assert names[0] is None and names.count("get_flags") == 1              # agent's toolset kept; ours replace dupes
    assert {"get_flags", "get_recent_readings", "get_baselines", "send_alert", "no_alert"} <= set(names)
    first = fake.sent[0][1][0]
    assert first["type"] == "user.message" and "send_alert or no_alert" in first["content"][0]["text"]
    result = fake.sent[1][1][0]
    assert result["type"] == "user.custom_tool_result" and result["custom_tool_use_id"] == "sevt_1"
    assert len(json.loads(result["content"][0]["text"])["readings"]) == 12
    assert fake.sent[2][1][0]["custom_tool_use_id"] == "sevt_2"           # the decision is acknowledged too


def test_managed_agent_ending_without_decision_falls_back_to_rules(env):
    from fengshui_server.monitor_agent import ManagedMonitorAgent
    fake = FakeManaged([ev("agent.message"), ev("session.status_idle", stop_reason=SimpleNamespace(type="end_turn"))])
    c, _ = env.make(agent=ManagedMonitorAgent(fake, "agent_x", environment_id="env_1"))
    sid = start(c)["id"]
    [a] = send(c, sid, [hr(T0 + i * 60, 128) for i in range(12)], ts=T0 + 720)["alerts"]
    assert a["decided_by"].startswith("rules (agent error")
