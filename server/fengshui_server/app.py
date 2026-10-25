"""Fengshui Mac server (spec §12): FastAPI + uvicorn, bearer-token auth, LAN only.

Endpoints: GET /health · POST /sync · POST /raw/archive · GET /raw · POST /compute ·
POST /diagnostics (+ GET /diagnostics/latest for reading uploads during the device test).
"""

from __future__ import annotations

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


class ComputeBody(BaseModel):
    engine_version: str
    since_id: int = 0
    now_ts: float
    tz: str
    tasks: list[str] | None = None


def create_app(settings: Settings | None = None, *, bonjour: bool = False, port: int = 8765) -> FastAPI:
    settings = settings or Settings()
    store = Store(settings.data_dir)
    zc_holder: dict = {}

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        if bonjour:
            zc_holder["zc"] = _advertise(port)
        yield
        if "zc" in zc_holder:
            zc_holder["zc"].close()

    app = FastAPI(title="Fengshui server", version=ENGINE_VERSION, lifespan=lifespan)
    app.state.store = store
    app.state.settings = settings

    def auth(authorization: str = Header(default="")):
        expected = f"Bearer {settings.token}"
        if not hmac.compare_digest(authorization.encode(), expected.encode()):
            raise HTTPException(401, "bad or missing bearer token")

    def check_version(v: str):
        if v != ENGINE_VERSION:
            raise HTTPException(409, f"engine version mismatch: phone {v}, server {ENGINE_VERSION}")

    @app.get("/health")
    def health():
        return {"ok": True, "engine_version": ENGINE_VERSION, "server_time": time.time()}

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


def _advertise(port: int):
    """Bonjour `_fengshui._tcp` so the phone can find the server on the LAN (spec §12)."""
    import socket

    from zeroconf import ServiceInfo, Zeroconf
    host = socket.gethostname()
    try:
        addr = socket.gethostbyname(host if host.endswith(".local") else host + ".local")
    except OSError:
        addr = "127.0.0.1"
    info = ServiceInfo("_fengshui._tcp.local.", f"Fengshui on {host.split('.')[0]}._fengshui._tcp.local.",
                       addresses=[socket.inet_aton(addr)], port=port,
                       properties={"engine": ENGINE_VERSION, "path": "/"})
    zc = Zeroconf()
    zc.register_service(info)
    return zc
