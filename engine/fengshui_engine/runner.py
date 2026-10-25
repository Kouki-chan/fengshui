"""Task dispatcher behind `fengshui_engine.run()`. Tasks are registered in Phase 4."""

from __future__ import annotations

import time

from . import ENGINE_VERSION, activity, db, features, places

# name -> callable(conn, ctx) -> dict(rows_written=..., warnings=[...]).
# Order matters when running "all": features before activity before wind_down.
TASKS: dict = {
    "features": features.run,
    "activity": activity.run,
    "place_suggestions": places.run,
}


def run(db_path: str, *, now_ts: float, tz: str, where: str,
        tasks: list[str] | None = None) -> dict:
    if where not in ("phone", "server"):
        raise ValueError(f"where must be 'phone' or 'server', not {where!r}")
    conn = db.connect(db_path)
    try:
        db.check_schema(conn)
        names = tasks if tasks is not None else list(TASKS)
        unknown = [n for n in names if n not in TASKS]
        summary = {"engine_version": ENGINE_VERSION, "where": where, "tasks": {},
                   "warnings": [f"unknown task {n}" for n in unknown]}
        ctx = {"now_ts": now_ts, "tz": tz, "where": where}
        for name in names:
            if name in unknown:
                continue
            t0 = time.perf_counter()
            # One transaction per task: a failed task leaves no partial rows behind.
            conn.execute("BEGIN IMMEDIATE")
            try:
                result = TASKS[name](conn, ctx) or {}
                conn.execute("COMMIT")
            except Exception:
                conn.execute("ROLLBACK")
                raise
            result["seconds"] = round(time.perf_counter() - t0, 4)
            summary["tasks"][name] = result
            summary["warnings"].extend(result.pop("warnings", []))
        return summary
    finally:
        conn.close()
