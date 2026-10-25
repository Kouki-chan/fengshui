import os
import shutil
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "engine"))
sys.path.insert(0, str(ROOT / "engine" / "tests"))
FIXTURES = ROOT / "fixtures"
CACHE = ROOT / "build" / "test-cache"


@pytest.fixture(scope="session")
def built():
    """Scenario DBs (with raw chunks) built once per session and cached on disk keyed by the
    scenario file's mtime; tests get a fresh copy each time."""
    import scenario_db
    import synth

    def get(name: str, tmp: Path, raw: bool = True):
        CACHE.mkdir(parents=True, exist_ok=True)
        src = FIXTURES / "scenarios" / f"{name}.json"
        key = CACHE / f"{name}-{int(src.stat().st_mtime)}-{int(raw)}.sqlite"
        if not key.exists():
            for old in CACHE.glob(f"{name}-*"):
                old.unlink()
            conn, _ = scenario_db.build(str(key) + ".tmp", name, raw=raw)
            conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
            conn.close()
            os.replace(str(key) + ".tmp", key)
        dst = tmp / f"{name}.sqlite"
        shutil.copy(key, dst)
        return dst, synth.load(name)
    return get
