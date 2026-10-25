"""Quick evaluation: run features + activity on a scenario and print agreement with truth.

    .venv/bin/python engine/tests/eval_scenario.py typical_week [db_path]
"""

import sys
import tempfile
import time
from pathlib import Path

sys.path[:0] = [str(Path(__file__).parent), str(Path(__file__).parents[1])]

import fengshui_engine  # noqa: E402
import scenario_db  # noqa: E402
import truth  # noqa: E402
from fengshui_engine.minute import minute_id  # noqa: E402


def main(name: str, path: str | None = None) -> None:
    path = path or str(Path(tempfile.mkdtemp()) / f"{name}.sqlite")
    t = time.perf_counter()
    conn, sc = scenario_db.build(path, name, raw=True)
    print(f"build {time.perf_counter() - t:.1f}s")
    for task in ["features", "activity"]:
        s = fengshui_engine.run(path, now_ts=sc["now"], tz=sc["tz"], where="phone", tasks=[task])
        print(task, s["tasks"][task])
    hi = minute_id(sc["now"])
    for title, lo in (("14 days", hi - 14 * 1440),
                      ("raw days", minute_id(sc["raw_plan"][0][0]) if sc["raw_plan"] else hi - 1440)):
        acc, conf, rec = truth.agreement(conn, sc, lo, hi)
        print(f"{title}: acc {acc:.3f}", {k: round(v, 2) for k, v in sorted(rec.items())})
        print("  top errors:", [(k, n) for k, n in conf.most_common(60) if k[0] != k[1]][:8])


if __name__ == "__main__":
    main(*sys.argv[1:])
