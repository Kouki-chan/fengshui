"""Server-side health monitor (DECISIONS D-19).

A session runs for a user-chosen duration and checks the user's readings at a user-chosen
interval. Each check: (1) fixed rules compare readings with limits and the user's own
baseline, (2) only when a rule flags something, the Claude agent (monitor_agent.py) looks at
the context through tools and decides whether and how to notify. Some flags always notify,
whatever the agent says. Readings are processed HealthKit values the phone sends; raw watch
data never reaches this module.

The server asks for readings with a silent push at each interval (paid account only). iOS
throttles silent pushes, so checks are best effort: every reading batch covers everything
recorded since the previous one, and the session reports how many intervals actually got data.
"""

from __future__ import annotations

import json
import math
import sqlite3
import time
from dataclasses import dataclass

MONITOR_SQL = [
    """CREATE TABLE IF NOT EXISTS monitor_sessions (
      id INTEGER PRIMARY KEY, device_id TEXT NOT NULL, created_at REAL NOT NULL,
      start_ts REAL NOT NULL, end_ts REAL NOT NULL, interval_s REAL NOT NULL, rules_json TEXT NOT NULL,
      push_token TEXT, push_env TEXT, status TEXT NOT NULL DEFAULT 'active',
      last_request_ts REAL, requests_sent INTEGER NOT NULL DEFAULT 0, push_errors INTEGER NOT NULL DEFAULT 0,
      last_push_error TEXT, stopped_at REAL)""",
    """CREATE TABLE IF NOT EXISTS monitor_readings (
      id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ts REAL NOT NULL, received_at REAL NOT NULL,
      trigger TEXT, samples_json TEXT NOT NULL, baselines_json TEXT NOT NULL)""",
    """CREATE TABLE IF NOT EXISTS monitor_alerts (
      id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, device_id TEXT NOT NULL, ts REAL NOT NULL,
      severity TEXT NOT NULL, title TEXT NOT NULL, body TEXT NOT NULL, flags_json TEXT NOT NULL,
      decided_by TEXT NOT NULL, pushed INTEGER NOT NULL DEFAULT 0)""",
    "CREATE INDEX IF NOT EXISTS ix_monitor_readings_session ON monitor_readings(session_id, ts)",
    "CREATE INDEX IF NOT EXISTS ix_monitor_alerts_device ON monitor_alerts(device_id, id)",
]

DEFAULT_RULES = {
    "hr_rest_high_bpm": 120,          # at rest, absolute
    "hr_rest_over_baseline_bpm": 30,  # at rest, above the user's resting HR
    "hr_very_high_bpm": 150,          # at rest, a single reading
    "hr_low_bpm": 40,
    "sustained_min": 10,              # high / low HR must last this long
    "rest_steps_per_min": 15,         # below this the user counts as resting
    "spo2_low_pct": 92,
    "spo2_urgent_pct": 88,
    "resp_high_per_min": 24,
    "resp_low_per_min": 8,
    "hrv_drop_frac": 0.5,             # HRV below half of baseline
    "cooldown_min": 60,               # don't repeat the same flag within this time
}

# Apple's own detections (HealthKit category events): always worth a notification.
APPLE_EVENTS = {
    "high_heart_rate_event": ("warning", "Apple Watch reported a high heart rate while you were inactive"),
    "low_heart_rate_event": ("warning", "Apple Watch reported a low heart rate"),
    "irregular_heart_rhythm_event": ("warning", "Apple Watch reported an irregular heart rhythm"),
    "low_cardio_fitness_event": ("info", "Apple Watch reported low cardio fitness"),
}
ALWAYS_NOTIFY = {"spo2_urgent", "hr_very_high", "irregular_heart_rhythm_event", "high_heart_rate_event",
                 "low_heart_rate_event"}
SEVERITY_RANK = {"info": 0, "warning": 1, "urgent": 2}

MIN_INTERVAL_S, MAX_INTERVAL_S = 60, 3600
MIN_DURATION_S, MAX_DURATION_S = 15 * 60, 24 * 3600


@dataclass
class Flag:
    code: str
    severity: str
    message: str
    value: float | None = None
    at: float | None = None

    def as_dict(self) -> dict:
        return {"code": self.code, "severity": self.severity, "message": self.message, "value": self.value,
                "at": self.at}


# ---------------------------------------------------------------- rules

def _by_label(samples: list[dict]) -> dict[str, list[dict]]:
    out: dict[str, list[dict]] = {}
    for s in samples:
        out.setdefault(s["label"], []).append(s)
    for v in out.values():
        v.sort(key=lambda s: s["ts"])
    return out


def _steps_per_min_around(steps: list[dict], ts: float, half_window: float = 300) -> float:
    total = 0.0
    for s in steps:
        end = s.get("end_ts") or s["ts"]
        overlap = min(end, ts + half_window) - max(s["ts"], ts - half_window)
        if overlap <= 0:
            continue
        span = max(end - s["ts"], 60)
        total += (s.get("value") or 0) * min(1.0, overlap / span)
    return total / (2 * half_window / 60)


def _sustained(readings: list[dict], minutes: float) -> list[dict] | None:
    """The first run of consecutive readings (gaps ≤ 10 min) spanning at least `minutes`."""
    run: list[dict] = []
    for r in readings:
        if run and r["ts"] - run[-1]["ts"] > 600:
            run = []
        run.append(r)
        if run[-1]["ts"] - run[0]["ts"] >= minutes * 60:
            return run
    return None


def evaluate(samples: list[dict], baselines: dict, rules: dict | None = None) -> list[Flag]:
    """Rule checks over one reading batch. Values are already in bpm, %, /min and ms."""
    r = {**DEFAULT_RULES, **(rules or {})}
    by = _by_label(samples)
    flags: list[Flag] = []
    steps = by.get("step_count", [])
    hr = [s for s in by.get("heart_rate", []) if s.get("value") is not None]
    rest_hr = [s for s in hr if _steps_per_min_around(steps, s["ts"]) < r["rest_steps_per_min"]]

    base_rest = baselines.get("resting_heart_rate")
    high = max(r["hr_rest_high_bpm"], (base_rest or 0) + r["hr_rest_over_baseline_bpm"])
    very = [s for s in rest_hr if s["value"] >= r["hr_very_high_bpm"]]
    if very:
        flags.append(Flag("hr_very_high", "urgent", f"Heart rate {very[-1]['value']:.0f} bpm while resting",
                          very[-1]["value"], very[-1]["ts"]))
    elif run := _sustained([s for s in rest_hr if s["value"] >= high], r["sustained_min"]):
        peak = max(x["value"] for x in run)
        flags.append(Flag("hr_rest_high", "warning",
                          f"Heart rate above {high:.0f} bpm for {(run[-1]['ts'] - run[0]['ts']) / 60:.0f} min while resting"
                          + (f" (your resting rate is about {base_rest:.0f})" if base_rest else ""), peak, run[-1]["ts"]))
    if run := _sustained([s for s in hr if s["value"] < r["hr_low_bpm"]], r["sustained_min"]):
        flags.append(Flag("hr_low", "warning",
                          f"Heart rate below {r['hr_low_bpm']} bpm for {(run[-1]['ts'] - run[0]['ts']) / 60:.0f} min",
                          min(x["value"] for x in run), run[-1]["ts"]))

    spo2 = [s for s in by.get("oxygen_saturation", []) if s.get("value") is not None]
    urgent = [s for s in spo2 if s["value"] < r["spo2_urgent_pct"]]
    low = [s for s in spo2 if s["value"] < r["spo2_low_pct"]]
    if urgent:
        flags.append(Flag("spo2_urgent", "urgent", f"Blood oxygen {urgent[-1]['value']:.0f} %", urgent[-1]["value"],
                          urgent[-1]["ts"]))
    elif len(low) >= 2:
        flags.append(Flag("spo2_low", "warning", f"Blood oxygen below {r['spo2_low_pct']} % in {len(low)} readings",
                          min(s["value"] for s in low), low[-1]["ts"]))
    elif low:
        flags.append(Flag("spo2_low_single", "info", f"One blood oxygen reading of {low[0]['value']:.0f} %",
                          low[0]["value"], low[0]["ts"]))

    for s in by.get("respiratory_rate", []):
        v = s.get("value")
        if v is not None and (v > r["resp_high_per_min"] or v < r["resp_low_per_min"]):
            flags.append(Flag("resp_out_of_range", "warning", f"Breathing rate {v:.0f} per minute", v, s["ts"]))
            break

    hrv = [s for s in by.get("heart_rate_variability_sdnn", []) if s.get("value") is not None]
    base_hrv = baselines.get("heart_rate_variability_sdnn")
    if hrv and base_hrv and hrv[-1]["value"] < base_hrv * (1 - r["hrv_drop_frac"]):
        flags.append(Flag("hrv_drop", "info", f"HRV {hrv[-1]['value']:.0f} ms, well below your usual {base_hrv:.0f} ms",
                          hrv[-1]["value"], hrv[-1]["ts"]))

    for label, (sev, msg) in APPLE_EVENTS.items():
        if ev := by.get(label):
            flags.append(Flag(label, sev, msg, None, ev[-1]["ts"]))
    return flags


# ---------------------------------------------------------------- storage

def init(conn: sqlite3.Connection) -> None:
    for sql in MONITOR_SQL:
        conn.execute(sql)


def session_row(conn, session_id: int) -> dict | None:
    conn.row_factory = sqlite3.Row
    r = conn.execute("SELECT * FROM monitor_sessions WHERE id=?", (session_id,)).fetchone()
    return dict(r) if r else None


def current_session(conn, device_id: str) -> dict | None:
    conn.row_factory = sqlite3.Row
    r = conn.execute("SELECT * FROM monitor_sessions WHERE device_id=? ORDER BY id DESC LIMIT 1", (device_id,)).fetchone()
    return dict(r) if r else None


def start_session(conn, *, device_id: str, interval_s: float, duration_s: float, now: float,
                  push_token: str | None, push_env: str | None, rules: dict | None) -> int:
    if not (MIN_INTERVAL_S <= interval_s <= MAX_INTERVAL_S):
        raise ValueError(f"interval must be {MIN_INTERVAL_S // 60}–{MAX_INTERVAL_S // 60} min")
    if not (MIN_DURATION_S <= duration_s <= MAX_DURATION_S):
        raise ValueError("duration must be 15 min – 24 h")
    unknown = set(rules or {}) - set(DEFAULT_RULES)
    if unknown:
        raise ValueError(f"unknown rules {sorted(unknown)}")
    conn.execute("UPDATE monitor_sessions SET status='stopped', stopped_at=? WHERE device_id=? AND status='active'",
                 (now, device_id))
    cur = conn.execute(
        "INSERT INTO monitor_sessions (device_id, created_at, start_ts, end_ts, interval_s, rules_json, push_token,"
        " push_env) VALUES (?,?,?,?,?,?,?,?)",
        (device_id, now, now, now + duration_s, interval_s, json.dumps({**DEFAULT_RULES, **(rules or {})}),
         push_token, push_env))
    return cur.lastrowid


def stats(conn, s: dict, now: float) -> dict:
    """Best-effort accounting: how many intervals so far actually received readings."""
    end = min(now, s["end_ts"], s["stopped_at"] or math.inf)
    slots = max(1, math.ceil((end - s["start_ts"]) / s["interval_s"]))
    rows = conn.execute("SELECT ts, received_at FROM monitor_readings WHERE session_id=? ORDER BY ts",
                        (s["id"],)).fetchall()
    with_data = {int((r[0] - s["start_ts"]) // s["interval_s"]) for r in rows if s["start_ts"] <= r[0] <= end + 60}
    gaps = sorted(rows[i + 1][0] - rows[i][0] for i in range(len(rows) - 1))
    alerts = conn.execute("SELECT COUNT(*) FROM monitor_alerts WHERE session_id=?", (s["id"],)).fetchone()[0]
    return {"intervals": slots, "intervals_with_data": min(len(with_data), slots),
            "coverage": round(min(len(with_data), slots) / slots, 3), "readings": len(rows),
            "last_reading_ts": rows[-1][0] if rows else None,
            "median_gap_s": gaps[len(gaps) // 2] if gaps else None,
            "requests_sent": s["requests_sent"], "push_errors": s["push_errors"], "alerts": alerts}


def public_session(conn, s: dict | None, now: float, *, push_configured: bool) -> dict | None:
    if s is None:
        return None
    active = s["status"] == "active" and now < s["end_ts"]
    next_due = (s["last_request_ts"] or s["start_ts"]) + s["interval_s"] if active else None
    return {"id": s["id"], "status": s["status"] if s["status"] != "active" or active else "ended",
            "start_ts": s["start_ts"], "end_ts": s["end_ts"], "interval_s": s["interval_s"],
            "rules": json.loads(s["rules_json"]), "next_due_ts": next_due,
            "mode": "push" if push_configured and s["push_token"] else "pull",
            "last_push_error": s["last_push_error"], "stats": stats(conn, s, now)}


def recent_flags(conn, session_id: int, now: float, cooldown_s: float) -> dict[str, str]:
    """code → highest severity alerted within the cooldown."""
    out: dict[str, str] = {}
    for flags_json, in conn.execute("SELECT flags_json FROM monitor_alerts WHERE session_id=? AND ts>=?",
                                    (session_id, now - cooldown_s)):
        for f in json.loads(flags_json):
            if SEVERITY_RANK[f["severity"]] >= SEVERITY_RANK.get(out.get(f["code"], "info"), 0):
                out[f["code"]] = f["severity"]
    return out


def new_flags(conn, session: dict, flags: list[Flag], now: float) -> list[Flag]:
    """Drops flags already alerted within the cooldown unless their severity went up."""
    rules = json.loads(session["rules_json"])
    seen = recent_flags(conn, session["id"], now, rules.get("cooldown_min", 60) * 60)
    return [f for f in flags if f.code not in seen or SEVERITY_RANK[f.severity] > SEVERITY_RANK[seen[f.code]]]


def add_alert(conn, session: dict, *, now: float, severity: str, title: str, body: str, flags: list[Flag],
              decided_by: str) -> dict:
    cur = conn.execute(
        "INSERT INTO monitor_alerts (session_id, device_id, ts, severity, title, body, flags_json, decided_by)"
        " VALUES (?,?,?,?,?,?,?,?)",
        (session["id"], session["device_id"], now, severity, title[:80], body[:400],
         json.dumps([f.as_dict() for f in flags]), decided_by))
    return alert_row(conn, cur.lastrowid)


def alert_row(conn, alert_id: int) -> dict:
    conn.row_factory = sqlite3.Row
    r = dict(conn.execute("SELECT * FROM monitor_alerts WHERE id=?", (alert_id,)).fetchone())
    r["flags"] = json.loads(r.pop("flags_json"))
    return r


def readings_window(conn, session_id: int, since: float) -> tuple[list[dict], dict]:
    """All samples received in this session since `since`, deduplicated, plus the latest baselines."""
    samples: dict[tuple, dict] = {}
    baselines: dict = {}
    for sj, bj in conn.execute("SELECT samples_json, baselines_json FROM monitor_readings WHERE session_id=? "
                               "AND ts>=? ORDER BY ts", (session_id, since)):
        for s in json.loads(sj):
            samples[(s["label"], s["ts"], s.get("value"), s.get("text"))] = s
        baselines.update(json.loads(bj))
    return sorted(samples.values(), key=lambda s: s["ts"]), baselines


def fallback_alert(flags: list[Flag]) -> tuple[str, str, str]:
    """Rule-only notification text when the agent is unavailable."""
    worst = max(flags, key=lambda f: SEVERITY_RANK[f.severity])
    title = {"urgent": "Check on yourself now", "warning": "Unusual reading"}.get(worst.severity, "Health note")
    body = "; ".join(f.message for f in flags[:3]) + "."
    if worst.severity == "urgent":
        body += " If you feel unwell, short of breath or faint, call emergency services."
    return worst.severity, title, body


# ---------------------------------------------------------------- one check

class Monitor:
    """Ties rules, agent and push together. `agent` and `push` may be None."""

    def __init__(self, store, *, agent=None, push=None, clock=time.time):
        self.store, self.agent, self.push, self.clock = store, agent, push, clock
        conn = store.connect()
        try:
            init(conn)
            conn.commit()
        finally:
            conn.close()

    @property
    def push_configured(self) -> bool:
        return self.push is not None

    def receive(self, session_id: int, *, ts: float, samples: list[dict], baselines: dict, trigger: str) -> dict:
        now = self.clock()
        conn = self.store.connect()
        try:
            s = session_row(conn, session_id)
            if s is None:
                raise KeyError(session_id)
            conn.execute("INSERT INTO monitor_readings (session_id, ts, received_at, trigger, samples_json,"
                         " baselines_json) VALUES (?,?,?,?,?,?)",
                         (session_id, ts, now, trigger, json.dumps(samples), json.dumps(baselines)))
            conn.commit()
            alerts = []
            if s["status"] == "active" and now <= s["end_ts"] + 300:
                flags = new_flags(conn, s, evaluate(samples, baselines, json.loads(s["rules_json"])), now)
                if flags:
                    alerts = self._decide(conn, s, flags, now)
            return {"alerts": alerts, "session": public_session(conn, session_row(conn, session_id), now,
                                                                push_configured=self.push_configured)}
        finally:
            conn.close()

    def _decide(self, conn, s: dict, flags: list[Flag], now: float) -> list[dict]:
        decision, decided_by = None, "rules"
        if self.agent is not None:
            try:
                decision = self.agent.decide(conn, s, flags, now)
                decided_by = "agent"
            except Exception as e:          # never lose an alert because Claude is unreachable
                decision, decided_by = None, f"rules (agent error: {type(e).__name__})"
        must = [f for f in flags if f.code in ALWAYS_NOTIFY]
        if decision is not None and not decision["notify"] and not must:
            return []
        if decision is None or not decision["notify"]:
            sev, title, body = fallback_alert(must or flags)
        else:
            sev, title, body = decision["severity"], decision["title"], decision["body"]
            if must:
                # The agent can't downgrade a hard-rule flag.
                worst = max(must, key=lambda f: SEVERITY_RANK[f.severity]).severity
                if SEVERITY_RANK[worst] > SEVERITY_RANK.get(sev, 0):
                    sev = worst
        alert = add_alert(conn, s, now=now, severity=sev, title=title, body=body, flags=flags, decided_by=decided_by)
        self._push_alert(conn, s, alert)
        conn.commit()
        return [alert]

    def _push_alert(self, conn, s: dict, alert: dict) -> None:
        if self.push is None or not s["push_token"]:
            return
        from .apns import alert_payload
        status, reason = self.push.send(s["push_token"], alert_payload(alert), background=False, env=s["push_env"])
        if status == 200:
            conn.execute("UPDATE monitor_alerts SET pushed=1 WHERE id=?", (alert["id"],))
            alert["pushed"] = 1
        else:
            conn.execute("UPDATE monitor_sessions SET push_errors=push_errors+1, last_push_error=? WHERE id=?",
                         (f"{status} {reason}", s["id"]))

    def tick(self) -> None:
        """Every ~15 s: ask due sessions for readings; close finished ones with a summary."""
        now = self.clock()
        conn = self.store.connect()
        try:
            conn.row_factory = sqlite3.Row
            for s in [dict(r) for r in conn.execute("SELECT * FROM monitor_sessions WHERE status='active'")]:
                if now >= s["end_ts"]:
                    conn.execute("UPDATE monitor_sessions SET status='ended' WHERE id=?", (s["id"],))
                    st = stats(conn, s, now)
                    alert = add_alert(conn, s, now=now, severity="info", title="Health monitoring finished",
                                      body=f"{st['intervals_with_data']} of {st['intervals']} checks had data, "
                                           f"{st['alerts']} alert{'s' if st['alerts'] != 1 else ''}.",
                                      flags=[], decided_by="summary")
                    self._push_alert(conn, s, alert)
                    continue
                if now - (s["last_request_ts"] or s["start_ts"] - s["interval_s"]) < s["interval_s"]:
                    continue
                conn.execute("UPDATE monitor_sessions SET last_request_ts=?, requests_sent=requests_sent+1 WHERE id=?",
                             (now, s["id"]))
                if self.push is not None and s["push_token"]:
                    from .apns import request_payload
                    status, reason = self.push.send(s["push_token"], request_payload(s["id"]), background=True,
                                                    env=s["push_env"], collapse_id=f"monitor-{s['id']}")
                    if status != 200:
                        conn.execute("UPDATE monitor_sessions SET push_errors=push_errors+1, last_push_error=? "
                                     "WHERE id=?", (f"{status} {reason}", s["id"]))
            conn.commit()
        finally:
            conn.close()
