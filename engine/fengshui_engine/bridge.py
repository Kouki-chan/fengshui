"""JSON-in/JSON-out entry points for the Swift host (apple/Fengshui/Python/PythonBridge.c).

Keeping the C side to "call(name, json) -> json" means Swift never handles
Python objects, and every function here is testable from pytest.
"""

from __future__ import annotations

import json
import sys
import time


def _version(_args: dict) -> dict:
    from . import version
    return {"version": version(), "python": sys.version.split()[0], "platform": sys.platform}


def _sqlite_probe(args: dict) -> dict:
    """Spike A: prove the embedded runtime can open and read the app's SQLite DB."""
    import sqlite3
    conn = sqlite3.connect(args["db_path"])
    try:
        tables = [r[0] for r in conn.execute(
            "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name")]
        row = conn.execute("SELECT MAX(version) FROM schema_version").fetchone() \
            if "schema_version" in tables else (None,)
        return {"tables": tables, "schema_version": row[0], "sqlite": sqlite3.sqlite_version}
    finally:
        conn.close()


def _zoneinfo_probe(args: dict) -> dict:
    """tzdata must be bundled for zoneinfo to work inside the iOS app."""
    from datetime import datetime, timezone
    from zoneinfo import ZoneInfo
    tz = ZoneInfo(args.get("tz", "America/New_York"))
    dt = datetime.fromtimestamp(args.get("ts", 0), timezone.utc).astimezone(tz)
    return {"local": dt.isoformat()}


def _check_schema(args: dict) -> dict:
    from . import db
    conn = db.connect(args["db_path"])
    try:
        return {"schema_version": db.check_schema(conn)}
    finally:
        conn.close()


def _dump(args: dict) -> dict:
    from .dump import canonical
    return {"canonical": canonical(args["db_path"])}


def _sleep_nights(args: dict) -> dict:
    """Processed nights for the Claude tool get_sleep_nights (same logic as wind_down)."""
    from . import db, sleep
    conn = db.connect(args["db_path"])
    try:
        out = []
        for n in sleep.nights(conn, args["tz"], args["start_ts"], args["end_ts"]):
            out.append({"night_of": (n.wake_date.fromordinal(n.wake_date.toordinal() - 1)).isoformat(),
                        "onset_ts": n.onset, "wake_ts": n.wake, "asleep_min": n.asleep_min,
                        "latency_min": n.latency_min, "in_bed_ts": n.in_bed_start, "stage_min": n.stage_min})
        return {"nights": out}
    finally:
        conn.close()


def _run(args: dict) -> dict:
    from . import run
    return run(args["db_path"], now_ts=args["now_ts"], tz=args["tz"], where=args["where"],
               tasks=args.get("tasks"))


FUNCTIONS = {
    "version": _version,
    "sqlite_probe": _sqlite_probe,
    "zoneinfo_probe": _zoneinfo_probe,
    "check_schema": _check_schema,
    "dump": _dump,
    "sleep_nights": _sleep_nights,
    "run": _run,
}


def call(name: str, args_json: str) -> str:
    """Never raises for engine errors: returns {"ok": false, "error": ...} so the
    Swift side can log it. Import errors in this module itself still raise."""
    t0 = time.perf_counter()
    try:
        fn = FUNCTIONS[name]
        result = fn(json.loads(args_json) if args_json else {})
        out = {"ok": True, "result": result}
    except Exception as e:  # noqa: BLE001 — surfaced to Swift verbatim
        out = {"ok": False, "error": f"{type(e).__name__}: {e}"}
    out["elapsed_s"] = round(time.perf_counter() - t0, 4)
    return json.dumps(out)
