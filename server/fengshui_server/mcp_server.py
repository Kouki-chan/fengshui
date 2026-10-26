"""Fengshui as an MCP server (DECISIONS D-21): `POST /mcp` on the Mac server (streamable HTTP,
stateless, JSON responses), behind the same bearer token as the rest of the API.

The tools mirror the phone's Claude tools over the server's copy of the data (whatever the
phone last synced). They are read-only: the database is opened with SQLite's read-only mode,
and no tool reads raw watch tables (raw_chunks, raw_minute_features).
"""

from __future__ import annotations

import hmac
import json
import os
import sqlite3
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

from mcp.server.mcpserver import MCPServer
from mcp.server.transport_security import TransportSecuritySettings

from fengshui_engine import sleep as fsleep

RAW_TABLES = ("raw_chunks", "raw_minute_features")
MAX_ROWS = 300
MAX_BUCKETS = 400
BUCKETS = {"5m": 300, "15m": 900, "1h": 3600, "1d": 86400}
INFERENCE_KINDS = ("activity_bout", "activity_day", "wind_down_plan", "wind_down_outcome")
VITALS = {"heart_rate", "resting_heart_rate", "walking_heart_rate_average", "heart_rate_variability_sdnn",
          "oxygen_saturation", "respiratory_rate", "blood_pressure_systolic", "blood_pressure_diastolic",
          "body_temperature", "apple_sleeping_wrist_temperature", "vo2_max", "heart_rate_recovery_one_minute",
          "blood_glucose"}
BODY = {"body_mass", "body_mass_index", "height", "body_fat_percentage", "lean_body_mass", "waist_circumference"}

INSTRUCTIONS = """Fengshui: one person's own health, activity, sleep and context data from their Apple Watch, \
iPhone and Apple Health, as last synced to their Mac. Processed data and engine inferences only, never raw sensor \
data. Dates are local (YYYY-MM-DD, inclusive). Call list_available_data first when unsure what exists. Values come \
from consumer devices and can be inaccurate; don't diagnose."""


def local_timezone() -> str:
    """The Mac's IANA zone (the phone and Mac share a home); FENGSHUI_TZ overrides."""
    if tz := os.environ.get("FENGSHUI_TZ"):
        return tz
    try:
        target = os.path.realpath("/etc/localtime")
        if "zoneinfo/" in target:
            return target.split("zoneinfo/", 1)[1]
    except OSError:
        pass
    return "UTC"


def group(label: str) -> str:
    if label in VITALS:
        return "Vitals"
    if label == "sleep_analysis" or label.startswith("sleeping_"):
        return "Sleep"
    if (label in ("workout", "step_count", "flights_climbed", "physical_effort") or label.startswith("distance_")
            or label.endswith("_energy_burned") or label.startswith(("apple_exercise", "apple_stand", "walking_", "running_"))):
        return "Activity"
    if label.endswith("_event"):
        return "Events"
    if label in BODY:
        return "Body"
    if label in ("state_of_mind", "mindful_session"):
        return "Mind"
    if label.startswith("dietary_"):
        return "Nutrition"
    return "Other"


def normalize(label: str, value: float | None, unit: str | None) -> tuple[float | None, str]:
    """Same everyday units as the app (DataSnapshot.normalize)."""
    if value is None:
        return None, unit or ""
    per_min = "bpm" if "heart_rate" in label else "/min"
    if unit == "count/s":
        return value * 60, per_min
    if unit == "count/min":
        return value, per_min
    if unit == "%":
        return (value * 100 if value <= 1 else value), "%"
    if unit == "count":
        return value, "steps" if label == "step_count" else ""
    return value, unit or ""


class Data:
    """Read-only queries over the server's mirror database."""

    def __init__(self, db_path: str, tz: str | None = None):
        self.db_path = db_path
        self.tz = tz or local_timezone()
        self.zone = ZoneInfo(self.tz)

    def connect(self) -> sqlite3.Connection:
        conn = sqlite3.connect(f"file:{Path(self.db_path).as_posix()}?mode=ro", uri=True)
        conn.row_factory = sqlite3.Row
        return conn

    def rows(self, sql: str, args: tuple = ()) -> list[sqlite3.Row]:
        low = sql.lower()
        if any(t in low for t in RAW_TABLES) or "payload" in low:
            raise ValueError("query touches raw watch data")
        conn = self.connect()
        try:
            return conn.execute(sql, args).fetchall()
        finally:
            conn.close()

    def day_range(self, start: str, end: str) -> tuple[float, float]:
        try:
            a = datetime.strptime(start[:10], "%Y-%m-%d").replace(tzinfo=self.zone)
            b = datetime.strptime(end[:10], "%Y-%m-%d").replace(tzinfo=self.zone) + timedelta(days=1)
        except ValueError:
            raise ValueError("dates must be YYYY-MM-DD") from None
        if b <= a:
            raise ValueError("end is before start")
        if (b - a).days > 400:
            raise ValueError("range too long (max 400 days)")
        return a.timestamp(), b.timestamp()

    def iso(self, ts: float | None) -> str | None:
        return None if ts is None else datetime.fromtimestamp(ts, self.zone).isoformat(timespec="seconds")

    # ---------------------------------------------------------------- tools

    def available(self) -> dict:
        labels = [{"label": r["label"], "group": group(r["label"]), "rows": r["n"], "first": self.iso(r["lo"]),
                   "last": self.iso(r["hi"])}
                  for r in self.rows("SELECT label, COUNT(*) n, MIN(start_ts) lo, MAX(end_ts) hi FROM processed_samples "
                                     "WHERE deleted=0 GROUP BY label ORDER BY n DESC")][:MAX_ROWS]
        kinds = [{"kind": r["kind"], "rows": r["n"], "first": self.iso(r["lo"] * 60), "last": self.iso(r["hi"] * 60)}
                 for r in self.rows("SELECT kind, COUNT(*) n, MIN(minute_start) lo, MAX(minute_end) hi FROM inferences "
                                    "WHERE superseded_by IS NULL GROUP BY kind")]
        places = [{"name": r["name"], "kind": r["kind"]}
                  for r in self.rows("SELECT name, kind FROM context_places WHERE kind != 'suggested'")]
        synced = self.rows("SELECT MAX(last_seen) t FROM devices")
        return {"labels": labels, "inference_kinds": kinds, "places": places, "time_zone": self.tz,
                "last_phone_sync": self.iso(synced[0]["t"]) if synced and synced[0]["t"] else None}

    def series(self, label: str, start: str, end: str, bucket: str, agg: str) -> dict:
        if bucket not in BUCKETS or agg not in ("avg", "sum", "min", "max"):
            raise ValueError("bucket must be 5m|15m|1h|1d and agg avg|sum|min|max")
        lo, hi = self.day_range(start, end)
        size = BUCKETS[bucket]
        if (hi - lo) / size > MAX_BUCKETS:
            raise ValueError(f"too many buckets (max {MAX_BUCKETS}); use a larger bucket or shorter range")
        offset = datetime.fromtimestamp(lo, self.zone).utcoffset().total_seconds() if bucket == "1d" else 0
        rows = self.rows(
            f"SELECT CAST((start_ts + ?) / ? AS INTEGER) b, {agg.upper()}(value) v, COUNT(*) n, MAX(unit) unit "
            "FROM processed_samples WHERE label=? AND deleted=0 AND value IS NOT NULL AND start_ts>=? AND start_ts<? "
            "GROUP BY b ORDER BY b", (offset, size, label, lo, hi))
        unit = rows[0]["unit"] if rows else None
        points = []
        for r in rows:
            v, u = normalize(label, r["v"], unit)
            points.append([self.iso(r["b"] * size - offset), round(v, 2), r["n"]])
        return {"label": label, "bucket": bucket, "agg": agg, "unit": normalize(label, 0, unit)[1], "points": points}

    def sleep_nights(self, start: str, end: str) -> dict:
        lo, hi = self.day_range(start, end)
        conn = self.connect()
        try:
            nights = fsleep.nights(conn, self.tz, lo, hi)
        finally:
            conn.close()
        return {"nights": [{"night_of": (n.wake_date - timedelta(days=1)).isoformat(), "onset": self.iso(n.onset),
                            "wake": self.iso(n.wake), "in_bed": self.iso(n.in_bed_start), "asleep_min": n.asleep_min,
                            "latency_min": n.latency_min, "stage_min": n.stage_min} for n in nights][:MAX_ROWS]}

    def inferences(self, kind: str, start: str, end: str) -> dict:
        if kind not in INFERENCE_KINDS:
            raise ValueError(f"kind must be one of {INFERENCE_KINDS}")
        lo, hi = self.day_range(start, end)
        rows = self.rows("SELECT value_json, confidence, provisional FROM inferences WHERE kind=? AND superseded_by IS NULL "
                         "AND minute_end>? AND minute_start<? ORDER BY minute_start LIMIT ?",
                         (kind, int(lo // 60), int(hi // 60), MAX_ROWS))
        out = []
        for r in rows:
            v = json.loads(r["value_json"])
            v["confidence"] = r["confidence"]
            if r["provisional"]:
                v["provisional"] = True
            out.append(v)
        return {"kind": kind, "rows": out, "truncated": len(rows) == MAX_ROWS}

    def visits(self, start: str, end: str) -> dict:
        lo, hi = self.day_range(start, end)
        rows = self.rows("SELECT v.arrival_ts a, v.departure_ts d, p.name name, p.kind kind FROM context_visits v "
                         "LEFT JOIN context_places p ON p.id = v.place_id WHERE v.arrival_ts < ? AND "
                         "(v.departure_ts IS NULL OR v.departure_ts > ?) ORDER BY v.arrival_ts LIMIT ?", (hi, lo, MAX_ROWS))
        # Place names only, never coordinates.
        return {"visits": [{"place": r["name"] or "unnamed place", "kind": r["kind"] or "unnamed",
                            "arrival": self.iso(r["a"]), "departure": self.iso(r["d"]),
                            "minutes": int((r["d"] - r["a"]) / 60) if r["d"] else None} for r in rows]}

    def report_labels(self, start: str, end: str) -> dict:
        lo, hi = self.day_range(start, end)
        groups: dict[str, list] = {}
        for r in self.rows("SELECT label, COUNT(*) n, MAX(unit) unit FROM processed_samples WHERE deleted=0 AND "
                           "start_ts>=? AND start_ts<? GROUP BY label ORDER BY label", (lo, hi)):
            groups.setdefault(group(r["label"]), []).append(
                {"label": r["label"], "rows": r["n"], "unit": normalize(r["label"], 0, r["unit"])[1]})
        return {"groups": groups}

    def monitor(self) -> dict:
        present = {r["name"] for r in self.rows("SELECT name FROM sqlite_master WHERE type='table'")}
        if "monitor_sessions" not in present:
            return {"session": None, "alerts": []}
        s = self.rows("SELECT id, status, start_ts, end_ts, interval_s FROM monitor_sessions ORDER BY id DESC LIMIT 1")
        alerts = self.rows("SELECT ts, severity, title, body FROM monitor_alerts ORDER BY id DESC LIMIT 20")
        return {"session": ({"status": s[0]["status"], "started": self.iso(s[0]["start_ts"]), "ends": self.iso(s[0]["end_ts"]),
                             "interval_min": s[0]["interval_s"] / 60} if s else None),
                "alerts": [{"time": self.iso(a["ts"]), "severity": a["severity"], "title": a["title"], "body": a["body"]}
                           for a in alerts]}


def build(db_path: str, tz: str | None = None) -> tuple[MCPServer, Data]:
    data = Data(db_path, tz)
    mcp = MCPServer("Fengshui", title="Fengshui health data", instructions=INSTRUCTIONS, version="0.1")
    read_only = {"readOnlyHint": True, "openWorldHint": False}

    @mcp.tool(annotations=read_only)
    def list_available_data() -> dict:
        """Which processed data labels exist (with groups, row counts and date ranges), which engine inference
        kinds exist, the named places, the time zone and when the phone last synced."""
        return data.available()

    @mcp.tool(annotations=read_only)
    def get_series(label: str, start: str, end: str, bucket: str = "1d", agg: str = "avg") -> dict:
        """A HealthKit series (e.g. heart_rate, step_count, resting_heart_rate) aggregated into buckets
        (5m, 15m, 1h, 1d; agg avg, sum, min or max) between two local dates YYYY-MM-DD, inclusive. Everyday units."""
        return data.series(label, start, end, bucket, agg)

    @mcp.tool(annotations=read_only)
    def get_sleep_nights(start: str, end: str) -> dict:
        """Main sleep per night between two local dates (by wake date): onset, wake, minutes asleep, stage minutes,
        sleep latency."""
        return data.sleep_nights(start, end)

    @mcp.tool(annotations=read_only)
    def get_inferences(kind: str, start: str, end: str) -> dict:
        """Engine inferences between two local dates: activity_bout, activity_day, wind_down_plan or wind_down_outcome."""
        return data.inferences(kind, start, end)

    @mcp.tool(annotations=read_only)
    def get_visits(start: str, end: str) -> dict:
        """Visits to the person's places (by name, no coordinates) between two local dates."""
        return data.visits(start, end)

    @mcp.tool(annotations=read_only)
    def list_report_labels(start: str, end: str) -> dict:
        """The labels with data between two local dates, grouped (Vitals, Sleep, Activity, Events, Body, Mind,
        Nutrition, Other), for choosing what a report to a health professional should include."""
        return data.report_labels(start, end)

    @mcp.tool(annotations=read_only)
    def get_monitor_status() -> dict:
        """The latest health-monitor session and its 20 most recent alerts."""
        return data.monitor()

    return mcp, data


class BearerAuth:
    """ASGI guard: the MCP endpoint needs the server's bearer token, like every other endpoint."""

    def __init__(self, app, token: str):
        self.app, self.expected = app, f"Bearer {token}".encode()

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            got = dict(scope.get("headers") or []).get(b"authorization", b"")
            if not hmac.compare_digest(got, self.expected):
                await send({"type": "http.response.start", "status": 401,
                            "headers": [(b"content-type", b"application/json"), (b"www-authenticate", b"Bearer")]})
                await send({"type": "http.response.body", "body": b'{"detail":"bad or missing bearer token"}'})
                return
        await self.app(scope, receive, send)


def asgi_app(mcp: MCPServer, token: str, hostnames: list[str]):
    """Streamable-HTTP app at /mcp. DNS-rebinding protection allows only this Mac's own names."""
    hosts = ["127.0.0.1:*", "localhost:*", "[::1]:*"] + [f"{h}:*" for h in hostnames]
    security = TransportSecuritySettings(enable_dns_rebinding_protection=True, allowed_hosts=hosts,
                                         allowed_origins=[f"http://{h}" for h in hosts])
    app = mcp.streamable_http_app(streamable_http_path="/mcp", stateless_http=True, json_response=True,
                                  transport_security=security)
    return BearerAuth(app, token)
