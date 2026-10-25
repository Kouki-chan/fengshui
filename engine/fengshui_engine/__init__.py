"""Fengshui inference engine.

Pure Python (standard library + tzdata) so the identical package runs inside
the iPhone app (embedded CPython) and on the Mac server.
"""

ENGINE_VERSION = "0.1.0"


def version() -> str:
    """Engine version string; phone and server compare it before exchanging results."""
    return ENGINE_VERSION


def run(db_path: str, *, now_ts: float, tz: str, where: str,
        tasks: list[str] | None = None, options: dict | None = None) -> dict:
    """Run the requested tasks (default: all due tasks) against the SQLite DB.

    Idempotent; uses engine_state watermarks. Returns a summary dict
    (tasks run, rows written, timings, warnings).
    """
    # Imported lazily so `version()` stays cheap for start-up checks.
    from .runner import run as _run
    return _run(db_path, now_ts=now_ts, tz=tz, where=where, tasks=tasks, options=options)
