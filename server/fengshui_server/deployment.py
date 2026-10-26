"""Serves the owner's scheduled deployment (DECISIONS D-22).

A deployment fires sessions on Anthropic's side with no client attached, so a session that
calls one of Fengshui's custom tools would wait forever. This watcher is that client: it lists
the deployment's runs, attaches to each new run's session, answers the custom tools from the
server's read-only copy of the data (the same tools as the MCP server), and files what the
agent wants the user to see as an inbox message on the phone (via /monitor/alerts).

Scheduled sessions only see tools defined **on the agent** (there are no per-run overrides),
so the agent needs these tool definitions: scripts/managed_agent_setup.py shows what's missing
and adds them when the owner asks it to (`--add-tools`).
"""

from __future__ import annotations

import json
import threading
import time

from . import monitor as mon
from .mcp_server import Data

MAX_TOOL_CALLS = 40


def _tool(name: str, desc: str, props: dict, required: list[str]) -> dict:
    return {"type": "custom", "name": name, "description": desc,
            "input_schema": {"type": "object", "properties": props, "required": required, "additionalProperties": False}}


DATE = {"type": "string", "description": "Local date YYYY-MM-DD"}
TOOLS = [
    _tool("list_available_data", "Which processed data labels exist with their date ranges and row counts, which inference "
          "kinds exist, the named places, and when the phone last synced. Call this first when unsure what data is available.",
          {}, []),
    _tool("get_series", "A HealthKit series (label such as heart_rate, step_count, resting_heart_rate) aggregated into time "
          "buckets between two local dates, inclusive. Everyday units.",
          {"label": {"type": "string"}, "start": DATE, "end": DATE,
           "bucket": {"type": "string", "enum": ["5m", "15m", "1h", "1d"]},
           "agg": {"type": "string", "enum": ["avg", "sum", "min", "max"]}}, ["label", "start", "end", "bucket", "agg"]),
    _tool("get_sleep_nights", "Main sleep per night between two local dates (by wake date): onset, wake, minutes asleep, "
          "stage minutes, sleep latency.", {"start": DATE, "end": DATE}, ["start", "end"]),
    _tool("get_inferences", "Engine inferences of one kind between two local dates, inclusive.",
          {"kind": {"type": "string", "enum": ["activity_bout", "activity_day", "wind_down_plan", "wind_down_outcome"]},
           "start": DATE, "end": DATE}, ["kind", "start", "end"]),
    _tool("get_visits", "Visits to the person's places (by name, no coordinates) between two local dates.",
          {"start": DATE, "end": DATE}, ["start", "end"]),
    _tool("list_report_labels", "Which data labels have samples between two local dates, grouped (Vitals, Sleep, Activity, "
          "Events, Body, Mind, Nutrition, Other).", {"start": DATE, "end": DATE}, ["start", "end"]),
    _tool("get_monitor_status", "The latest health-monitor session and its most recent alerts.", {}, []),
    _tool("notify_user", "Put a message in the person's Fengshui inbox on their iPhone (and push it when push is set up). "
          "Use for the result of a scheduled check-in. Title at most 50 characters, body at most 300.",
          {"title": {"type": "string"}, "body": {"type": "string"},
           "severity": {"type": "string", "enum": ["info", "warning", "urgent"]}}, ["title", "body", "severity"]),
]
TOOL_NAMES = {t["name"] for t in TOOLS}
PHONE_ONLY = {"create_report", "propose_report_labels"}

RUNS_SQL = """CREATE TABLE IF NOT EXISTS agent_runs (
  run_id TEXT PRIMARY KEY, session_id TEXT, started_at REAL NOT NULL, finished_at REAL, status TEXT NOT NULL,
  tool_calls INTEGER NOT NULL DEFAULT 0, error TEXT)"""


class DeploymentWatcher:
    def __init__(self, client, deployment_id: str, store, *, push=None, clock=time.time, tz: str | None = None):
        self.client, self.deployment_id, self.store, self.push, self.clock = client, deployment_id, store, push, clock
        self.data = Data(store.db_path, tz)
        self._active: set[str] = set()
        self._lock = threading.Lock()
        conn = store.connect()
        try:
            conn.execute(RUNS_SQL)
            conn.commit()
        finally:
            conn.close()

    # ------------------------------------------------------------ polling

    def tick(self, *, wait: bool = False) -> list[str]:
        """Attaches to runs not handled yet; returns their session ids. `wait` serves inline (tests)."""
        conn = self.store.connect()
        try:
            known = {r[0] for r in conn.execute("SELECT run_id FROM agent_runs")}
        finally:
            conn.close()
        started = []
        for run in self.client.beta.deployment_runs.list(deployment_id=self.deployment_id, limit=20):
            sid = getattr(run, "session_id", None)
            if run.id in known or not sid or getattr(run, "error", None):
                continue
            with self._lock:
                if sid in self._active:
                    continue
                self._active.add(sid)
            self._record(run.id, sid, "serving")
            started.append(sid)
            if wait:
                self.serve(run.id, sid)
            else:
                threading.Thread(target=self.serve, args=(run.id, sid), daemon=True).start()
        return started

    def _record(self, run_id: str, sid: str, status: str, *, calls: int = 0, error: str | None = None) -> None:
        conn = self.store.connect()
        try:
            conn.execute("INSERT INTO agent_runs (run_id, session_id, started_at, status) VALUES (?,?,?,?) "
                         "ON CONFLICT(run_id) DO UPDATE SET status=excluded.status", (run_id, sid, self.clock(), status))
            if status != "serving":
                conn.execute("UPDATE agent_runs SET finished_at=?, tool_calls=?, error=? WHERE run_id=?",
                             (self.clock(), calls, error, run_id))
            conn.commit()
        finally:
            conn.close()

    # ------------------------------------------------------------ one session

    def serve(self, run_id: str, sid: str) -> None:
        calls, error, texts, notified = 0, None, [], False
        try:
            stream = self.client.beta.sessions.events.stream(sid, timeout=300)
            # The run may have asked for tools before we attached: answer those from history first.
            answered = set()
            pending = []
            for ev in self.client.beta.sessions.events.list(sid, limit=1000):
                if ev.type == "user.custom_tool_result":
                    answered.add(ev.custom_tool_use_id)
                elif ev.type == "agent.custom_tool_use":
                    pending.append(ev)
                elif ev.type == "agent.message":
                    texts.extend(b.text for b in (ev.content or []) if getattr(b, "type", "") == "text")
            done = False
            for ev in [e for e in pending if e.id not in answered]:
                calls += 1
                answered.add(ev.id)
                notified |= self._answer(sid, ev, calls)
            for ev in stream:
                if ev.type == "agent.custom_tool_use":
                    if ev.id in answered:            # already answered from history
                        continue
                    calls += 1
                    answered.add(ev.id)
                    notified |= self._answer(sid, ev, calls)
                elif ev.type == "agent.message":
                    texts.extend(b.text for b in (ev.content or []) if getattr(b, "type", "") == "text")
                elif ev.type == "session.status_terminated":
                    done = True
                    break
                elif ev.type == "session.status_idle" and getattr(ev.stop_reason, "type", "") != "requires_action":
                    done = True
                    break
            if not done:
                error = "stream closed before the session finished"
            # A check-in that ended without notify_user still reaches the user.
            if not notified and texts:
                self._notify({"title": "Scheduled check-in", "body": "\n\n".join(texts)[-300:], "severity": "info"})
        except Exception as e:          # noqa: BLE001 — recorded; the next tick doesn't retry a served run
            error = f"{type(e).__name__}: {e}"
        finally:
            self._record(run_id, sid, "error" if error else "done", calls=calls, error=error)
            with self._lock:
                self._active.discard(sid)

    def _answer(self, sid: str, ev, n: int) -> bool:
        name, args = ev.name, dict(ev.input or {})
        notified = False
        try:
            if n > MAX_TOOL_CALLS:
                out, err = "Tool budget reached for this run. Finish with what you have.", True
            elif name in PHONE_ONLY:
                out, err = f"{name} only works in the Fengshui app on the iPhone.", True
            elif name == "notify_user":
                self._notify(args)
                out, err, notified = "Delivered to the person's Fengshui inbox.", False, True
            else:
                out, err = json.dumps(self._run(name, args), separators=(",", ":"))[:12_000], False
        except Exception as e:          # noqa: BLE001 — returned to the agent as a tool error
            out, err = f"Error: {e}", True
        self.client.beta.sessions.events.send(sid, events=[{
            "type": "user.custom_tool_result", "custom_tool_use_id": ev.id,
            "content": [{"type": "text", "text": out}], "is_error": err}])
        return notified

    def _run(self, name: str, a: dict) -> dict:
        d = self.data
        match name:
            case "list_available_data": return d.available()
            case "get_series": return d.series(a["label"], a["start"], a["end"], a.get("bucket", "1d"), a.get("agg", "avg"))
            case "get_sleep_nights": return d.sleep_nights(a["start"], a["end"])
            case "get_inferences": return d.inferences(a["kind"], a["start"], a["end"])
            case "get_visits": return d.visits(a["start"], a["end"])
            case "list_report_labels": return d.report_labels(a["start"], a["end"])
            case "get_monitor_status": return d.monitor()
        raise ValueError(f"unknown tool {name}")

    def _notify(self, a: dict) -> None:
        """Filed as a monitor alert for the phone's last-seen device, so it lands in the inbox."""
        conn = self.store.connect()
        try:
            row = conn.execute("SELECT device_id FROM devices ORDER BY last_seen DESC LIMIT 1").fetchone()
            device = row[0] if row else "unknown"
            s = {"id": 0, "device_id": device, "push_token": None, "push_env": None}
            tok = conn.execute("SELECT push_token, push_env FROM monitor_sessions WHERE device_id=? AND push_token IS NOT NULL "
                               "ORDER BY id DESC LIMIT 1", (device,)).fetchone()
            if tok:
                s["push_token"], s["push_env"] = tok
            sev = a.get("severity") if a.get("severity") in mon.SEVERITY_RANK else "info"
            alert = mon.add_alert(conn, s, now=self.clock(), severity=sev, title=str(a.get("title", "Fengshui"))[:80],
                                  body=str(a.get("body", ""))[:400], flags=[], decided_by="deployment")
            mon.Monitor._push_alert(SimpleMonitor(self.push), conn, s, alert)
            conn.commit()
        finally:
            conn.close()


class SimpleMonitor:
    """Just enough of Monitor for _push_alert (push client only)."""

    def __init__(self, push):
        self.push = push
