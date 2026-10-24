import json

from conftest import FIXTURES
from fengshui_engine import db
from fengshui_engine.export_key import export_key, find_export_match, format_value

# Shared with FengshuiKit ExportKeyTests.
VECTORS = [
    ("HKQuantityTypeIdentifierHeartRate", 1792754100.0, 1792754100.0, "Test Watch", 62.0, None),
    ("HKQuantityTypeIdentifierHeartRate", 1792754100.4, 1792754100.6, "Test Watch", 64.5, None),
    ("HKQuantityTypeIdentifierStepCount", 1792775640.5, 1792776480.0, "Test iPhone", 1512.0, None),
    ("HKCategoryTypeIdentifierSleepAnalysis", 1792724700.0, 1792753260.0, "Test Watch", 3.0, "asleep_core"),
    ("HKCategoryTypeIdentifierHeadache", 1792782000.0, 1792785600.0, None, None, "severity_mild"),
    ("HKQuantityTypeIdentifierVO2Max", 1792795200.0, 1792795200.0, "Test Watch", 41.23456789, None),
    ("HKQuantityTypeIdentifierBodyMass", 1792795200.0, 1792795200.0, "Scale ü", 1e-05, None),
]


def test_vectors_file_current():
    want = [{"hk_type": t, "start": s, "end": e, "source_name": src, "value": v, "value_text": vt,
             "key": export_key(t, s, e, src, v, vt)} for t, s, e, src, v, vt in VECTORS]
    path = FIXTURES / "export_keys.json"
    if not path.exists() or json.loads(path.read_text()) != want:
        path.write_text(json.dumps(want, indent=1, ensure_ascii=False) + "\n")
    assert json.loads(path.read_text()) == want


def test_format_value():
    assert format_value(62.0) == "62"
    assert format_value(64.5) == "64.5"
    assert format_value(None) == ""
    assert format_value(1e-05) == "1e-05"


def test_half_second_rounds_up_like_swift():
    a = export_key("X", 10.5, 11.5, "s", None, None)
    assert a == export_key("X", 11.0, 12.0, "s", None, None)


def _insert(conn, uuid, label, start, end, src, value, text):
    conn.execute("INSERT INTO processed_samples (hk_uuid, hk_type, label, value, value_text, start_ts, end_ts,"
                 " minute_id, source_name, inserted_at) VALUES (?,?,?,?,?,?,?,?,?,0)",
                 (uuid, "T", label, value, text, start, end, int(start // 60), src))


def test_find_export_match(tmp_path):
    c = db.create(str(tmp_path / "t.sqlite"))
    _insert(c, "export:a", "headache", 1000.0, 4600.0, "Phone", None, "severity_mild")
    _insert(c, "export:b", "heart_rate", 2000.0, 2000.0, "Watch", 62.0, None)
    _insert(c, "export:w", "workout", 3000.0, 4830.0, "Watch", 1830.0, "running")
    _insert(c, "real-uuid", "heart_rate", 5000.0, 5000.0, "Watch", 62.0, None)
    # Category: HealthKit gives raw value 2, same text → adopt.
    assert find_export_match(c, label="headache", start=1000.2, end=4600.0, source_name="Phone",
                             value=2.0, value_text="severity_mild") is not None
    # Quantity within tolerance, sub-second times.
    assert find_export_match(c, label="heart_rate", start=1999.6, end=2000.4, source_name="Watch",
                             value=62.0004, value_text=None) is not None
    # Different value → no match.
    assert find_export_match(c, label="heart_rate", start=2000.0, end=2000.0, source_name="Watch",
                             value=63.0, value_text=None) is None
    # Different source → no match.
    assert find_export_match(c, label="heart_rate", start=2000.0, end=2000.0, source_name="Phone",
                             value=62.0, value_text=None) is None
    # Workout duration differs (rounded minutes in export) → still adopt.
    assert find_export_match(c, label="workout", start=3000.0, end=4830.4, source_name="Watch",
                             value=1830.4321, value_text="running") is not None
    # Rows with real UUIDs are never candidates.
    assert find_export_match(c, label="heart_rate", start=5000.0, end=5000.0, source_name="Watch",
                             value=62.0, value_text=None) is None
