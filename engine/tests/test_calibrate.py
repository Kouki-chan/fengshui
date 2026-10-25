import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "tools"))

import calibrate  # noqa: E402


def test_calibration_without_override_detects_logged_workouts(built, tmp_path):
    p, sc = built("typical_week", tmp_path, raw=False)
    r = calibrate.calibrate(str(p), now=sc["now"], tz=sc["tz"], days=28)
    assert r["running"]["workouts"] == 8 and r["running"]["recall"] >= 0.95
    assert r["cycling"]["workouts"] == 4 and r["cycling"]["recall"] >= 0.9
    assert r["running"]["precision_lower_bound"] >= 0.9
