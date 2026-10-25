"""Server database: the same v1 schema as the phone, plus a `devices` table, and the
raw-chunk archive on disk (blobs stored unchanged, partitioned by UTC day)."""

from __future__ import annotations

import base64
import hashlib
import sqlite3
from datetime import datetime, timezone
from pathlib import Path

from fengshui_engine import db as fdb
from fengshui_engine.export_key import find_export_match

DEVICES_SQL = """CREATE TABLE IF NOT EXISTS devices (
  device_id TEXT PRIMARY KEY, name TEXT, engine_version TEXT, last_seen REAL NOT NULL)"""

# table -> natural key columns used for idempotent upserts (spec §12 "idempotent by natural keys").
# Tables keyed by `id` mirror the phone's row ids: the phone owns those ids.
NATURAL_KEYS = {
    "processed_samples": ("hk_uuid",),
    "processed_route_points": ("workout_uuid", "ts"),
    "characteristics": ("key",),
    "context_motion": ("start_ts", "activity"),
    "context_places": ("id",),
    "context_visits": ("id",),
    "context_screen_events": ("ts", "schedule", "threshold_min"),
    "preferences": ("key",),
    "inferences": ("id",),
    "engine_state": ("key",),
    "notifications_log": ("id",),
    "ai_questions": ("id",),
    "ai_log": ("id",),
    # Unprocessed raw minutes, only so /compute can extract features (DECISIONS D-16).
    "raw_chunks": ("minute_id", "sensor", "tier"),
}


class Store:
    def __init__(self, data_dir: Path):
        self.dir = data_dir
        self.dir.mkdir(parents=True, exist_ok=True)
        self.db_path = str(self.dir / "server.sqlite")
        self.raw_dir = self.dir / "raw"
        conn = fdb.create(self.db_path)
        conn.execute(DEVICES_SQL)
        conn.close()
        self._cols: dict[str, list[str]] = {}

    def connect(self) -> sqlite3.Connection:
        return fdb.connect(self.db_path)

    def columns(self, conn, table: str) -> list[str]:
        if table not in self._cols:
            self._cols[table] = [r[1] for r in conn.execute(f"PRAGMA table_info({table})")]
        return self._cols[table]

    # ------------------------------------------------------------ sync

    def upsert(self, conn, table: str, rows: list[dict]) -> int:
        if table not in NATURAL_KEYS:
            raise KeyError(table)
        cols = self.columns(conn, table)
        keys = NATURAL_KEYS[table]
        n = 0
        for r in rows:
            if "payload_b64" in r:          # blobs travel base64-encoded inside JSON
                r = {**r, "payload": base64.b64decode(r["payload_b64"]) if r["payload_b64"] else None}
            r = {k: v for k, v in r.items() if k in cols}
            if table == "processed_samples":
                n += self._upsert_sample(conn, r, cols)
                continue
            if table != "inferences" and "id" in r and keys != ("id",):
                r.pop("id")          # server-local ids for tables keyed naturally
            names = list(r)
            updates = [c for c in names if c not in keys]
            sql = (f"INSERT INTO {table} ({','.join(names)}) VALUES ({','.join('?' * len(names))}) "
                   f"ON CONFLICT({','.join(keys)}) DO " +
                   (f"UPDATE SET {','.join(f'{c}=excluded.{c}' for c in updates)}" if updates else "NOTHING"))
            if table == "raw_chunks":
                sql += " WHERE raw_chunks.archive_ref IS NULL"
            conn.execute(sql, [r[c] for c in names])
            n += 1
        return n

    def _upsert_sample(self, conn, r: dict, cols: list[str]) -> int:
        r.pop("id", None)
        exists = conn.execute("SELECT id FROM processed_samples WHERE hk_uuid=?", (r["hk_uuid"],)).fetchone()
        if exists:
            # HealthKit samples are immutable; only the deletion flag changes.
            conn.execute("UPDATE processed_samples SET deleted=? WHERE id=?", (r.get("deleted", 0), exists[0]))
            return 1
        if not r["hk_uuid"].startswith("export:"):
            mid = find_export_match(conn, label=r["label"], start=r["start_ts"], end=r["end_ts"],
                                    source_name=r.get("source_name"), value=r.get("value"),
                                    value_text=r.get("value_text"))
            if mid is not None:
                # A Health-export row adopts the real HealthKit UUID (DECISIONS D-06).
                sets = [c for c in r if c not in ("label", "hk_type")]
                conn.execute(f"UPDATE processed_samples SET {','.join(f'{c}=?' for c in sets)} WHERE id=?",
                             [r[c] for c in sets] + [mid])
                return 1
        names = list(r)
        conn.execute(f"INSERT INTO processed_samples ({','.join(names)}) VALUES ({','.join('?' * len(names))})",
                     [r[c] for c in names])
        return 1

    def mark_deleted(self, conn, uuids: list[str]) -> None:
        for i in range(0, len(uuids), 500):
            part = uuids[i:i + 500]
            conn.execute(f"UPDATE processed_samples SET deleted=1 WHERE hk_uuid IN ({','.join('?' * len(part))})", part)

    def touch_device(self, conn, device_id: str, name: str | None, engine_version: str) -> None:
        conn.execute("INSERT INTO devices (device_id, name, engine_version, last_seen) VALUES (?,?,?,?) "
                     "ON CONFLICT(device_id) DO UPDATE SET name=excluded.name, engine_version=excluded.engine_version,"
                     " last_seen=excluded.last_seen",
                     (device_id, name, engine_version, datetime.now(timezone.utc).timestamp()))

    # ------------------------------------------------------------ raw archive

    def archive(self, conn, chunk: dict, payload: bytes) -> str:
        """Store a chunk's blob unchanged; return its archive_ref (relative path)."""
        day = datetime.fromtimestamp(chunk["minute_id"] * 60, timezone.utc).strftime("%Y-%m-%d")
        rel = f"{day}/{chunk['minute_id']}_{chunk['sensor']}_{chunk['tier']}.fsr1"
        path = self.raw_dir / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        if not path.exists() or path.read_bytes() != payload:
            tmp = path.with_suffix(".tmp")
            tmp.write_bytes(payload)
            tmp.replace(path)
        now = datetime.now(timezone.utc).timestamp()
        conn.execute(
            "INSERT INTO raw_chunks (minute_id, sensor, tier, rate_hz, sample_count, axes, encoding, scale, offset,"
            " payload, archive_ref, archived_at, received_at) VALUES (?,?,?,?,?,?,?,?,?,NULL,?,?,?) "
            "ON CONFLICT(minute_id, sensor, tier) DO UPDATE SET payload=NULL, archive_ref=excluded.archive_ref,"
            " archived_at=excluded.archived_at",
            (chunk["minute_id"], chunk["sensor"], chunk["tier"], chunk["rate_hz"], chunk["sample_count"],
             chunk["axes"], chunk["encoding"], chunk["scale"], chunk.get("offset", 0.0), rel, now, now))
        return rel

    def read_archived(self, conn, sensor: str, lo: int, hi: int) -> list[tuple[dict, bytes]]:
        out = []
        for r in conn.execute("SELECT * FROM raw_chunks WHERE sensor=? AND minute_id BETWEEN ? AND ? "
                              "ORDER BY minute_id, tier", (sensor, lo, hi)):
            d = dict(r)
            if d["archive_ref"]:
                blob = (self.raw_dir / d["archive_ref"]).read_bytes()
            elif d["payload"] is not None:
                blob = d["payload"]
            else:
                continue
            d.pop("payload", None)
            d["sha256"] = hashlib.sha256(blob).hexdigest()
            out.append((d, blob))
        return out
