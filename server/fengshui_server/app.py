"""Fengshui Mac server (spec §12): FastAPI + uvicorn, bearer-token auth, LAN only.

Endpoints: GET /health · POST /sync · POST /raw/archive · GET /raw · POST /compute ·
POST /diagnostics (+ GET /diagnostics/latest for reading uploads during the device test).
Health monitor (DECISIONS D-19): POST /monitor/sessions · GET /monitor/sessions/current ·
POST /monitor/sessions/{id}/stop · POST /monitor/readings · GET /monitor/alerts.
MCP (DECISIONS D-21): POST /mcp, the read-only data tools for any MCP client.
"""

from __future__ import annotations

import asyncio
import base64
import hmac
import json
import os
import time
from contextlib import asynccontextmanager
from datetime import datetime, timezone
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from pydantic import BaseModel, Field

import fengshui_engine
from fengshui_engine import ENGINE_VERSION

from . import mcp_server
from . import monitor as mon
from .store import NATURAL_KEYS, Store

ROOT = Path(__file__).resolve().parents[1]


class Settings:
    def __init__(self, data_dir: Path | None = None, token: str | None = None, diagnostics_dir: Path | None = None):
        env = _read_env(ROOT / ".env")
        self.token = token or os.environ.get("FENGSHUI_TOKEN") or env.get("FENGSHUI_TOKEN")
        if not self.token:
            raise RuntimeError("no FENGSHUI_TOKEN: run scripts/run_server.sh once to generate server/.env")
        self.data_dir = data_dir or Path(os.environ.get("FENGSHUI_DATA_DIR") or env.get("FENGSHUI_DATA_DIR")
                                         or ROOT / "data")
        self.diagnostics_dir = diagnostics_dir or ROOT / "diagnostics"
        self.env = env


def _read_env(p: Path) -> dict:
    if not p.exists():
        return {}
    out = {}
    for line in p.read_text().splitlines():
        if "=" in line and not line.lstrip().startswith("#"):
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    return out


# ---------------------------------------------------------------- request models

class SyncBody(BaseModel):
    device_id: str
    device_name: str | None = None
    engine_version: str
    tables: dict[str, list[dict]] = Field(default_factory=dict)
    deleted_uuids: list[str] = Field(default_factory=list)


class RawChunkIn(BaseModel):
    minute_id: int
    sensor: str
    tier: int
    rate_hz: float
    sample_count: int
    axes: int
    encoding: str
    scale: float
    offset: float = 0.0
    payload_b64: str


class ArchiveBody(BaseModel):
    chunks: list[RawChunkIn]


class MonitorStartBody(BaseModel):
    device_id: str
    interval_min: float
    duration_h: float
    push_token: str | None = None
    push_env: str | None = None          # "sandbox" for Xcode builds, "production" for TestFlight / App Store
    rules: dict[str, float] = Field(default_factory=dict)


class MonitorReadingsBody(BaseModel):
    session_id: int
    ts: float
    trigger: str = "pull"                # push | pull | foreground | background
    samples: list[dict] = Field(default_factory=list)
    baselines: dict[str, float] = Field(default_factory=dict)


class ComputeBody(BaseModel):
    engine_version: str
    since_id: int = 0
    now_ts: float
    tz: str
    tasks: list[str] | None = None


def create_app(settings: Settings | None = None, *, bonjour: bool = False, port: int = 8765,
               monitor_agent=None, push=None, scheduler: bool = False, clock=time.time) -> FastAPI:
    settings = settings or Settings()
    store = Store(settings.data_dir)
    monitor = mon.Monitor(store, agent=monitor_agent, push=push, clock=clock)
    mcp, _ = mcp_server.build(store.db_path)
    import socket
    host = socket.gethostname().split(".")[0]
    mcp_app = mcp_server.asgi_app(mcp, settings.token, [host, f"{host}.local", socket.gethostname()])
    zc_holder: dict = {}

    async def monitor_loop():
        while True:
            try:
                await asyncio.to_thread(monitor.tick)
            except Exception as e:          # keep the loop alive; the next tick retries
                print(f"monitor tick failed: {e}")
            await asyncio.sleep(15)

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if bonjour:
            zc_holder["zc"] = await _advertise(port)
        task = asyncio.create_task(monitor_loop()) if scheduler else None
        async with mcp.session_manager.run():
            yield
        if task:
            task.cancel()
        if "zc" in zc_holder:
            await zc_holder["zc"].async_close()

    app = FastAPI(title="Fengshui server", version=ENGINE_VERSION, lifespan=lifespan)
    app.state.store = store
    app.state.settings = settings
    app.state.monitor = monitor
    # An ASGI route: the MCP transport handles GET / POST / DELETE itself.
    from starlette.routing import Route
    app.router.routes.append(Route("/mcp", endpoint=mcp_app))

    def auth(authorization: str = Header(default="")):
        expected = f"Bearer {settings.token}"
        if not hmac.compare_digest(authorization.encode(), expected.encode()):
            raise HTTPException(401, "bad or missing bearer token")

    def check_version(v: str):
        if v != ENGINE_VERSION:
            raise HTTPException(409, f"engine version mismatch: phone {v}, server {ENGINE_VERSION}")

    @app.get("/health")
    def health():
        return {"ok": True, "engine_version": ENGINE_VERSION, "server_time": time.time(),
                "monitor": {"push": monitor.push_configured, "agent": monitor.agent is not None}}

    # ------------------------------------------------------------ health monitor (D-19)

    @app.post("/monitor/sessions", dependencies=[Depends(auth)])
    def monitor_start(body: MonitorStartBody):
        conn = store.connect()
        try:
            try:
                sid = mon.start_session(conn, device_id=body.device_id, interval_s=body.interval_min * 60,
                                        duration_s=body.duration_h * 3600, now=clock(), push_token=body.push_token,
                                        push_env=body.push_env, rules=body.rules)
            except ValueError as e:
                raise HTTPException(400, str(e))
            conn.commit()
            return mon.public_session(conn, mon.session_row(conn, sid), clock(), push_configured=monitor.push_configured)
        finally:
            conn.close()

    @app.get("/monitor/sessions/current", dependencies=[Depends(auth)])
    def monitor_current(device_id: str):
        conn = store.connect()
        try:
            return {"session": mon.public_session(conn, mon.current_session(conn, device_id), clock(),
                                                  push_configured=monitor.push_configured)}
        finally:
            conn.close()

    @app.post("/monitor/sessions/{session_id}/stop", dependencies=[Depends(auth)])
    def monitor_stop(session_id: int):
        conn = store.connect()
        try:
            if mon.session_row(conn, session_id) is None:
                raise HTTPException(404, "no such session")
            conn.execute("UPDATE monitor_sessions SET status='stopped', stopped_at=? WHERE id=? AND status='active'",
                         (clock(), session_id))
            conn.commit()
            return mon.public_session(conn, mon.session_row(conn, session_id), clock(),
                                      push_configured=monitor.push_configured)
        finally:
            conn.close()

    @app.post("/monitor/readings", dependencies=[Depends(auth)])
    def monitor_readings(body: MonitorReadingsBody):
        try:
            return monitor.receive(body.session_id, ts=body.ts, samples=body.samples, baselines=body.baselines,
                                   trigger=body.trigger)
        except KeyError:
            raise HTTPException(404, "no such session")

    @app.get("/monitor/alerts", dependencies=[Depends(auth)])
    def monitor_alerts(device_id: str, since_id: int = 0):
        conn = store.connect()
        try:
            ids = [r[0] for r in conn.execute("SELECT id FROM monitor_alerts WHERE device_id=? AND id>? ORDER BY id "
                                              "LIMIT 200", (device_id, since_id))]
            return {"alerts": [mon.alert_row(conn, i) for i in ids]}
        finally:
            conn.close()

    @app.post("/sync", dependencies=[Depends(auth)])
    def sync(body: SyncBody):
        check_version(body.engine_version)
        unknown = set(body.tables) - set(NATURAL_KEYS)
        if unknown:
            raise HTTPException(400, f"unknown tables {sorted(unknown)}")
        conn = store.connect()
        try:
            conn.execute("BEGIN IMMEDIATE")
            accepted = {t: store.upsert(conn, t, rows) for t, rows in body.tables.items()}
            store.mark_deleted(conn, body.deleted_uuids)
            store.touch_device(conn, body.device_id, body.device_name, body.engine_version)
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise
        finally:
            conn.close()
        return {"accepted": accepted, "deleted": len(body.deleted_uuids)}

    @app.post("/raw/archive", dependencies=[Depends(auth)])
    def raw_archive(body: ArchiveBody):
        conn = store.connect()
        refs = []
        try:
            conn.execute("BEGIN IMMEDIATE")
            for c in body.chunks:
                d = c.model_dump()
                payload = base64.b64decode(d.pop("payload_b64"))
                refs.append({"minute_id": c.minute_id, "sensor": c.sensor, "tier": c.tier,
                             "archive_ref": store.archive(conn, d, payload)})
            conn.execute("COMMIT")
        except Exception:
            conn.execute("ROLLBACK")
            raise
        finally:
            conn.close()
        # The phone clears its payloads only after receiving these refs (spec §12).
        return {"archived": refs}

    @app.get("/raw", dependencies=[Depends(auth)])
    def raw(sensor: str, from_minute: int = Query(...), to_minute: int = Query(...)):
        conn = store.connect()
        try:
            rows = store.read_archived(conn, sensor, from_minute, to_minute)
        finally:
            conn.close()
        return {"chunks": [{**meta, "payload_b64": base64.b64encode(blob).decode()} for meta, blob in rows]}

    @app.post("/compute", dependencies=[Depends(auth)])
    def compute(body: ComputeBody):
        check_version(body.engine_version)
        summary = fengshui_engine.run(store.db_path, now_ts=body.now_ts, tz=body.tz, where="server", tasks=body.tasks)
        conn = store.connect()
        try:
            cols = [r[1] for r in conn.execute("PRAGMA table_info(inferences)")]
            rows = [dict(zip(cols, r)) for r in conn.execute(
                "SELECT * FROM inferences WHERE id > ? OR superseded_by > ? ORDER BY id", (body.since_id, body.since_id))]
            fcols = [r[1] for r in conn.execute("PRAGMA table_info(raw_minute_features)")]
            feats = [dict(zip(fcols, r)) for r in conn.execute(
                "SELECT * FROM raw_minute_features WHERE computed_at = ?", (body.now_ts,))]
            state = dict(conn.execute("SELECT key, value FROM engine_state").fetchall())
        finally:
            conn.close()
        return {"engine_version": ENGINE_VERSION, "summary": summary, "inferences": rows,
                "raw_minute_features": feats, "engine_state": state}

    @app.post("/diagnostics", dependencies=[Depends(auth)])
    def diagnostics(report: dict):
        settings.diagnostics_dir.mkdir(parents=True, exist_ok=True)
        name = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ") + ".json"
        (settings.diagnostics_dir / name).write_text(json.dumps(report, indent=1, sort_keys=True))
        return {"stored": name}

    @app.get("/diagnostics/latest", dependencies=[Depends(auth)])
    def diagnostics_latest():
        files = sorted(settings.diagnostics_dir.glob("*.json")) if settings.diagnostics_dir.exists() else []
        if not files:
            raise HTTPException(404, "no diagnostics uploaded yet")
        return json.loads(files[-1].read_text())

    return app


async def _advertise(port: int):
    """Bonjour `_fengshui._tcp` so the phone can find the server on the LAN (spec §12).
    Async API: the sync one deadlocks inside uvicorn's event loop."""
    import socket

    from zeroconf import ServiceInfo
    from zeroconf.asyncio import AsyncZeroconf
    host = socket.gethostname()
    try:
        addr = socket.gethostbyname(host if host.endswith(".local") else host + ".local")
    except OSError:
        addr = "127.0.0.1"
    info = ServiceInfo("_fengshui._tcp.local.", f"Fengshui on {host.split('.')[0]}._fengshui._tcp.local.",
                       addresses=[socket.inet_aton(addr)], port=port,
                       properties={"engine": ENGINE_VERSION, "path": "/"})
    zc = AsyncZeroconf()
    # A second server, or a restart before the old record expires, gets "… (2)" instead of failing.
    await zc.async_register_service(info, allow_name_change=True)
    return zc
