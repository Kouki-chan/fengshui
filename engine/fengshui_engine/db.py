"""SQLite access shared by every engine task.

Connection settings follow spec §4: WAL, busy_timeout 5000, foreign keys on.
The engine refuses to run against a schema version it doesn't know.
"""

from __future__ import annotations

import sqlite3
from importlib import resources

SUPPORTED_SCHEMA_VERSIONS = (1,)
LATEST_SCHEMA_VERSION = 1

# Tables every v1 database must have; used by the schema check.
V1_TABLES = frozenset({
    "schema_version", "processed_samples", "processed_route_points", "characteristics",
    "raw_chunks", "raw_minute_features", "context_motion", "context_places",
    "context_visits", "context_screen_events", "inferences", "engine_state",
    "notifications_log", "preferences", "sync_state", "server_sync_state",
    "ai_questions", "ai_log",
})


class SchemaError(RuntimeError):
    pass


def schema_sql(version: int = LATEST_SCHEMA_VERSION) -> str:
    return resources.files(__package__).joinpath(f"schema_v{version}.sql").read_text()


def connect(path: str) -> sqlite3.Connection:
    conn = sqlite3.connect(path, timeout=5.0, isolation_level=None)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA busy_timeout = 5000")
    conn.execute("PRAGMA foreign_keys = ON")
    mode = conn.execute("PRAGMA journal_mode = WAL").fetchone()[0]
    if path != ":memory:" and mode.lower() != "wal":
        raise SchemaError(f"could not enable WAL (got {mode})")
    return conn


def create(path: str) -> sqlite3.Connection:
    """Create a fresh v1 database (used by the importer, server and tests)."""
    conn = connect(path)
    if not _has_table(conn, "schema_version"):
        conn.executescript(schema_sql())
    check_schema(conn)
    return conn


def _has_table(conn: sqlite3.Connection, name: str) -> bool:
    return conn.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (name,)
    ).fetchone() is not None


def schema_version(conn: sqlite3.Connection) -> int:
    if not _has_table(conn, "schema_version"):
        raise SchemaError("no schema_version table")
    row = conn.execute("SELECT MAX(version) FROM schema_version").fetchone()
    if row[0] is None:
        raise SchemaError("schema_version is empty")
    return int(row[0])


def check_schema(conn: sqlite3.Connection) -> int:
    """Raise SchemaError unless the DB is a known version with all expected tables."""
    v = schema_version(conn)
    if v not in SUPPORTED_SCHEMA_VERSIONS:
        raise SchemaError(f"unknown schema version {v}; engine supports {SUPPORTED_SCHEMA_VERSIONS}")
    present = {r[0] for r in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    missing = V1_TABLES - present
    if missing:
        raise SchemaError(f"missing tables: {sorted(missing)}")
    return v


def get_state(conn: sqlite3.Connection, key: str, default: str | None = None) -> str | None:
    row = conn.execute("SELECT value FROM engine_state WHERE key=?", (key,)).fetchone()
    return row[0] if row else default


def set_state(conn: sqlite3.Connection, key: str, value: str) -> None:
    conn.execute(
        "INSERT INTO engine_state(key, value) VALUES(?, ?) "
        "ON CONFLICT(key) DO UPDATE SET value=excluded.value", (key, value))
