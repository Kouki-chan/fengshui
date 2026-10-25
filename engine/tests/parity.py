"""Prepare the phone/Mac parity check (spec §14.2 Phase 4 gate).

Builds the `typical_week` scenario DB with raw chunks into build/parity/source.sqlite,
runs every engine task on a copy on the Mac, and writes the canonical dump to
build/parity/mac.json. The iOS test EngineParityTests runs the embedded engine on its
own copy with the same arguments and must produce the identical dump.

    .venv/bin/python engine/tests/parity.py
"""

import json
import shutil
import sys
import time
from pathlib import Path

sys.path[:0] = [str(Path(__file__).parent), str(Path(__file__).parents[1])]

import fengshui_engine  # noqa: E402
import scenario_db  # noqa: E402
from fengshui_engine.dump import canonical  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "build" / "parity"
SCENARIO = "typical_week"
TASKS = ["features", "activity", "wind_down_outcome", "wind_down", "place_suggestions"]


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    src = OUT / "source.sqlite"
    for f in OUT.glob("source.sqlite*"):
        f.unlink()
    conn, sc = scenario_db.build(str(src), SCENARIO, raw=True)
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    conn.close()
    mac = OUT / "mac.sqlite"
    shutil.copy(src, mac)
    args = {"now_ts": sc["now"], "tz": sc["tz"], "where": "phone", "tasks": TASKS}
    t0 = time.perf_counter()
    summary = fengshui_engine.run(str(mac), **args)
    secs = time.perf_counter() - t0
    (OUT / "args.json").write_text(json.dumps(args))
    (OUT / "mac.json").write_text(canonical(str(mac)))
    feat = summary["tasks"]["features"]
    print(f"parity prepared: {SCENARIO}, mac run {secs:.1f}s, features {feat['rows_written']} minutes "
          f"in {feat['seconds']:.1f}s")


if __name__ == "__main__":
    main()
