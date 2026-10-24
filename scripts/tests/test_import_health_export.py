import json
import sqlite3
import sys
import zipfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts"))
sys.path.insert(0, str(ROOT / "engine"))

import import_health_export as imp  # noqa: E402
from fengshui_engine import db as fdb  # noqa: E402
from fengshui_engine.export_key import export_key  # noqa: E402

SAMPLE = ROOT / "fixtures" / "health_export_sample.xml"


def run(tmp_path, *extra):
    db = tmp_path / "out.sqlite"
    rc = imp.main(["--xml", str(SAMPLE), "--db", str(db), "--report", str(tmp_path / "report.md"), *extra])
    assert rc == 0
    conn = sqlite3.connect(db)
    conn.row_factory = sqlite3.Row
    return conn


def test_output_passes_engine_schema_check(tmp_path):
    run(tmp_path)
    assert fdb.check_schema(fdb.connect(str(tmp_path / "out.sqlite"))) == 1


def test_records_and_labels(tmp_path):
    c = run(tmp_path)
    counts = dict(c.execute("SELECT label, COUNT(*) FROM processed_samples GROUP BY label").fetchall())
    assert counts["heart_rate"] == 2
    assert counts["step_count"] == 1          # exact duplicate collapsed; bad-date record skipped
    assert counts["heart_rate_variability_sdnn"] == 1
    assert counts["vo2_max"] == 1
    assert counts["sleep_analysis"] == 5
    assert counts["blood_pressure_systolic"] == 1 and counts["blood_pressure_diastolic"] == 1
    assert counts["workout"] == 1 and counts["activity_summary"] == 1


def test_values_units_and_times(tmp_path):
    c = run(tmp_path)
    hr = c.execute("SELECT * FROM processed_samples WHERE label='heart_rate' ORDER BY start_ts").fetchone()
    assert hr["value"] == 62 and hr["unit"] == "count/min"
    assert hr["start_ts"] == 1792754100.0              # 2026-10-23 07:15:00 -0400
    assert hr["minute_id"] == 1792754100 // 60
    assert hr["source_name"] == "Test Watch"
    assert hr["device"].startswith("name:Apple Watch") and "0x" not in hr["device"]
    meta = json.loads(hr["metadata_json"])
    assert meta["HKMetadataKeyHeartRateMotionContext"] == "1"
    assert hr["hk_uuid"] == export_key("HKQuantityTypeIdentifierHeartRate", hr["start_ts"], hr["end_ts"],
                                       "Test Watch", 62.0, None)


def test_categories(tmp_path):
    c = run(tmp_path)
    sleep = [tuple(r) for r in c.execute(
        "SELECT value_text, value FROM processed_samples WHERE label='sleep_analysis' ORDER BY start_ts")]
    assert sleep == [("in_bed", 0), ("asleep_core", 3), ("asleep_deep", 4), ("awake", 2), ("asleep_rem", 5)]
    stand = c.execute("SELECT value_text FROM processed_samples WHERE label='apple_stand_hour'").fetchone()[0]
    assert stand == "stood"
    assert c.execute("SELECT value_text FROM processed_samples WHERE label='headache'").fetchone()[0] == "severity_mild"


def test_hrv_beats_in_metadata(tmp_path):
    c = run(tmp_path)
    meta = json.loads(c.execute(
        "SELECT metadata_json FROM processed_samples WHERE label='heart_rate_variability_sdnn'").fetchone()[0])
    assert meta["beats"] == [["3:09:01.12 AM", 58.0], ["3:09:02.10 AM", 60.0]]


def test_workout_and_route(tmp_path):
    c = run(tmp_path)
    w = c.execute("SELECT * FROM processed_samples WHERE label='workout'").fetchone()
    assert w["value"] == 30.5 * 60 and w["value_text"] == "running" and w["unit"] == "s"
    meta = json.loads(w["metadata_json"])
    assert {s["type"] for s in meta["statistics"]} == {"HKQuantityTypeIdentifierDistanceWalkingRunning",
                                                       "HKQuantityTypeIdentifierHeartRate"}
    assert meta["events"][0]["type"] == "HKWorkoutEventTypeSegment"
    pts = c.execute("SELECT * FROM processed_route_points WHERE workout_uuid=? ORDER BY ts", (w["hk_uuid"],)).fetchall()
    assert len(pts) == 3
    assert pts[0]["ts"] == 1792794600.0 and pts[0]["speed_mps"] == 2.9 and pts[0]["h_accuracy"] == 4.5
    assert pts[1]["alt_m"] == 10.3


def test_me_and_activity_summary(tmp_path):
    c = run(tmp_path)
    ch = dict(c.execute("SELECT key, value FROM characteristics").fetchall())
    assert ch["date_of_birth"] == "1991-05-17"
    assert ch["biological_sex"] == "female"
    assert ch["blood_type"] == "not_set" and ch["skin_type"] == "not_set"
    a = c.execute("SELECT * FROM processed_samples WHERE label='activity_summary'").fetchone()
    assert a["value_text"] == "2026-10-23"
    assert a["start_ts"] == 1792728000.0  # local midnight America/New_York (-04:00)
    assert json.loads(a["metadata_json"])["apple_exercise_time"] == "41"


def test_reimport_adds_nothing(tmp_path):
    run(tmp_path).close()
    db = tmp_path / "out.sqlite"
    n1 = sqlite3.connect(db).execute("SELECT COUNT(*) FROM processed_samples").fetchone()[0]
    p1 = sqlite3.connect(db).execute("SELECT COUNT(*) FROM processed_route_points").fetchone()[0]
    run(tmp_path).close()
    assert sqlite3.connect(db).execute("SELECT COUNT(*) FROM processed_samples").fetchone()[0] == n1
    assert sqlite3.connect(db).execute("SELECT COUNT(*) FROM processed_route_points").fetchone()[0] == p1
    assert "inserted: 0" in (tmp_path / "report.md").read_text()


def test_newer_export_adds_only_new_rows(tmp_path):
    run(tmp_path).close()
    newer = tmp_path / "newer.xml"
    text = SAMPLE.read_text().replace(
        "</HealthData>",
        ' <Record type="HKQuantityTypeIdentifierHeartRate" sourceName="Test Watch" unit="count/min" '
        'startDate="2026-10-24 09:00:00 -0400" endDate="2026-10-24 09:00:00 -0400" value="70"/>\n</HealthData>')
    newer.write_text(text)
    (tmp_path / "workout-routes").symlink_to(ROOT / "fixtures" / "workout-routes")
    db = tmp_path / "out.sqlite"
    before = sqlite3.connect(db).execute("SELECT COUNT(*) FROM processed_samples").fetchone()[0]
    assert imp.main(["--xml", str(newer), "--db", str(db), "--report", str(tmp_path / "r2.md")]) == 0
    assert sqlite3.connect(db).execute("SELECT COUNT(*) FROM processed_samples").fetchone()[0] == before + 1


def test_report_contents(tmp_path):
    run(tmp_path)
    r = (tmp_path / "report.md").read_text()
    assert "| heart_rate | 2 |" in r
    assert "Test Watch" in r and "name:Apple Watch" in r
    assert "1 unparseable records" in r
    assert "clinical records" in r


def test_csv_flag(tmp_path):
    run(tmp_path, "--csv")
    files = {p.name for p in (tmp_path / "csv").glob("*.csv")}
    assert {"heart_rate.csv", "workout.csv", "sleep_analysis.csv"} <= files
    assert len((tmp_path / "csv" / "heart_rate.csv").read_text().strip().splitlines()) == 3


def test_zip_extraction_never_modifies_zip(tmp_path):
    z = tmp_path / "export.zip"
    with zipfile.ZipFile(z, "w") as zf:
        zf.write(SAMPLE, "apple_health_export/export.xml")
        zf.write(ROOT / "fixtures/workout-routes/route_2026-10-23_6.30pm.gpx",
                 "apple_health_export/workout-routes/route_2026-10-23_6.30pm.gpx")
    before = (z.stat().st_size, z.stat().st_mtime, z.read_bytes())
    assert imp.main(["--dir", str(tmp_path)]) == 0
    assert (z.stat().st_size, z.stat().st_mtime, z.read_bytes()) == before
    assert (tmp_path / "fengshui_health.sqlite").exists() and (tmp_path / "import_report.md").exists()
    assert sqlite3.connect(tmp_path / "fengshui_health.sqlite").execute(
        "SELECT COUNT(*) FROM processed_route_points").fetchone()[0] == 3


def test_parse_date():
    assert imp.parse_date("2026-10-24 07:15:00 -0400") == 1792840500.0
    assert imp.parse_date("2026-01-01 00:00:00 +0530") == 1767205800.0
    with pytest.raises(ValueError):
        imp.parse_date("nope")
