#!/usr/bin/env python3
"""Import an Apple Health export into a Fengshui v1 SQLite database (spec Task B).

    .venv/bin/python scripts/import_health_export.py            # ~/Desktop/HealthExport defaults
    .venv/bin/python scripts/import_health_export.py --csv
    .venv/bin/python scripts/import_health_export.py --xml fixtures/health_export_sample.xml --db /tmp/t.sqlite

Standard library only (plus the repo's pure-stdlib fengshui_engine package).
export.xml can be several GB: it is parsed streaming with iterparse and every
element is cleared after use. Re-running adds only rows not already present
(hk_uuid = "export:" + sha1 of the sample tuple, DECISIONS D-06).
The original export.zip is never modified.
"""

from __future__ import annotations

import argparse
import calendar
import csv
import json
import os
import re
import sqlite3
import sys
import time
import zipfile
from collections import defaultdict
from pathlib import Path
from xml.etree.ElementTree import iterparse

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "engine"))

from fengshui_engine import db as fdb  # noqa: E402
from fengshui_engine.export_key import export_key  # noqa: E402
from fengshui_engine.hk_labels import (SLEEP_RAW, category_value_text,  # noqa: E402
                                       label_for_identifier, snake)
from fengshui_engine.minute import minute_id  # noqa: E402

DEFAULT_DIR = Path.home() / "Desktop" / "HealthExport"
BATCH = 5000

# ---------------------------------------------------------------- parsing helpers

_DATE = re.compile(r"(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d) ([+-])(\d\d)(\d\d)")


def parse_date(s: str) -> float:
    """'2026-10-24 07:15:00 -0400' → UTC unix seconds. ~10× faster than strptime."""
    m = _DATE.fullmatch(s.strip())
    if not m:
        raise ValueError(f"bad date {s!r}")
    y, mo, d, h, mi, se, sign, oh, om = m.groups()
    ts = calendar.timegm((int(y), int(mo), int(d), int(h), int(mi), int(se), 0, 0, 0))
    off = (int(oh) * 3600 + int(om) * 60) * (1 if sign == "+" else -1)
    return float(ts - off)


def parse_iso(s: str) -> float:
    """GPX times: '2026-10-08T21:13:05Z' or with offset / fractional seconds."""
    from datetime import datetime
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


_DEVICE_PTR = re.compile(r"<<HKDevice: 0x[0-9a-f]+>, ?")


def clean_device(d: str | None) -> str | None:
    # The pointer differs between exports; drop it so the field is stable.
    return _DEVICE_PTR.sub("", d).rstrip(">").strip() if d else None


def to_float(s: str | None) -> float | None:
    if s is None:
        return None
    try:
        return float(s)
    except ValueError:
        return None


DURATION_UNITS = {"min": 60.0, "s": 1.0, "sec": 1.0, "hr": 3600.0, "h": 3600.0}

# ---------------------------------------------------------------- importer


class Importer:
    def __init__(self, conn: sqlite3.Connection, export_root: Path | None, tz_name: str):
        self.conn = conn
        self.root = export_root
        self.tz_name = tz_name
        self.now = time.time()
        self.rows: list[tuple] = []
        self.route_rows: list[tuple] = []
        self.stats = {"records_seen": 0, "inserted": 0, "duplicates": 0,
                      "route_points_inserted": 0, "unparseable": 0}
        self.label_counts: dict[str, int] = defaultdict(int)
        self.warnings: list[str] = []
        self.unknown_types: dict[str, int] = defaultdict(int)
        self.sources: dict[str, int] = defaultdict(int)
        self.devices: dict[str, int] = defaultdict(int)
        self.correlations = 0

    # -- buffering

    def add_sample(self, hk_type: str, label: str, value: float | None, value_text: str | None,
                   unit: str | None, start: float, end: float, source: str | None,
                   source_bundle: str | None, device: str | None, meta: dict | None) -> str:
        uuid = export_key(hk_type, start, end, source, value, value_text)
        self.rows.append((uuid, hk_type, label, value, value_text, unit, start, end, minute_id(start),
                          source, source_bundle, device,
                          json.dumps(meta, separators=(",", ":")) if meta else None, self.now))
        self.stats["records_seen"] += 1
        self.label_counts[label] += 1
        if source:
            self.sources[source] += 1
        if device:
            self.devices[device.split(", manufacturer")[0]] += 1
        if len(self.rows) >= BATCH:
            self.flush()
        return uuid

    def flush(self) -> None:
        if self.rows:
            before = self.conn.total_changes
            self.conn.execute("BEGIN")
            self.conn.executemany(
                "INSERT OR IGNORE INTO processed_samples (hk_uuid, hk_type, label, value, value_text, unit,"
                " start_ts, end_ts, minute_id, source_name, source_bundle, device, metadata_json, inserted_at)"
                " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", self.rows)
            self.conn.execute("COMMIT")
            n = self.conn.total_changes - before
            self.stats["inserted"] += n
            self.stats["duplicates"] += len(self.rows) - n
            self.rows.clear()
        if self.route_rows:
            before = self.conn.total_changes
            self.conn.execute("BEGIN")
            self.conn.executemany(
                "INSERT OR IGNORE INTO processed_route_points (workout_uuid, ts, minute_id, lat, lon, alt_m,"
                " speed_mps, h_accuracy) VALUES (?,?,?,?,?,?,?,?)", self.route_rows)
            self.conn.execute("COMMIT")
            self.stats["route_points_inserted"] += self.conn.total_changes - before
            self.route_rows.clear()

    # -- element handlers

    def record(self, el) -> None:
        a = el.attrib
        hk_type = a.get("type", "")
        try:
            start, end = parse_date(a["startDate"]), parse_date(a["endDate"])
        except (KeyError, ValueError):
            self.stats["unparseable"] += 1
            if self.stats["unparseable"] <= 20:
                self.warnings.append(f"unparseable Record dates: type={hk_type}")
            return
        raw_value = a.get("value")
        value, value_text = to_float(raw_value), None
        if hk_type.startswith("HKCategoryTypeIdentifier"):
            if raw_value is not None and value is None:
                value_text = category_value_text(hk_type, raw_value)
                if hk_type == "HKCategoryTypeIdentifierSleepAnalysis":
                    value = SLEEP_RAW.get(value_text)
        elif raw_value is not None and value is None:
            value_text = raw_value
        elif not hk_type.startswith(("HKQuantityTypeIdentifier", "HKDataType")):
            self.unknown_types[hk_type] += 1

        meta = {}
        for child in el:
            if child.tag == "MetadataEntry":
                meta[child.get("key")] = child.get("value")
            elif child.tag == "HeartRateVariabilityMetadataList":
                meta["beats"] = [[b.get("time"), to_float(b.get("bpm"))]
                                 for b in child.iter("InstantaneousBeatsPerMinute")]
        if a.get("sourceVersion"):
            meta["source_version"] = a["sourceVersion"]
        if a.get("creationDate"):
            meta["creation_date"] = a["creationDate"]
        self.add_sample(hk_type, label_for_identifier(hk_type), value, value_text, a.get("unit"),
                        start, end, a.get("sourceName"), None, clean_device(a.get("device")), meta or None)

    def workout(self, el) -> None:
        a = el.attrib
        try:
            start, end = parse_date(a["startDate"]), parse_date(a["endDate"])
        except (KeyError, ValueError):
            self.stats["unparseable"] += 1
            return
        dur = to_float(a.get("duration"))
        dur_s = dur * DURATION_UNITS.get(a.get("durationUnit", "min"), 60.0) if dur is not None else end - start
        activity = label_for_identifier(a.get("workoutActivityType", "HKWorkoutActivityTypeOther"))
        meta: dict = {"statistics": [], "events": [], "metadata": {}}
        routes = []
        for child in el:
            t = child.tag
            if t == "MetadataEntry":
                meta["metadata"][child.get("key")] = child.get("value")
            elif t == "WorkoutEvent":
                meta["events"].append(dict(child.attrib))
            elif t == "WorkoutStatistics":
                meta["statistics"].append(dict(child.attrib))
            elif t == "WorkoutRoute":
                for f in child.iter("FileReference"):
                    routes.append(f.get("path"))
        for k in ("totalDistance", "totalDistanceUnit", "totalEnergyBurned", "totalEnergyBurnedUnit"):
            if k in a:
                meta[snake(k)] = a[k]
        uuid = self.add_sample("HKWorkoutTypeIdentifier", "workout", dur_s, activity, "s", start, end,
                               a.get("sourceName"), None, clean_device(a.get("device")), meta)
        for path in routes:
            self.route(uuid, path)

    def route(self, workout_uuid: str, ref: str | None) -> None:
        if not ref or not self.root:
            return
        gpx = self.root / ref.lstrip("/")
        if not gpx.exists():
            self.warnings.append(f"missing route file {ref}")
            return
        for _, el in iterparse(gpx, events=("end",)):
            if el.tag.endswith("trkpt"):
                vals = {c.tag.split("}")[-1]: c.text for c in el.iter()}
                t = vals.get("time")
                if t:
                    ts = parse_iso(t)
                    self.route_rows.append((workout_uuid, ts, minute_id(ts), to_float(el.get("lat")),
                                            to_float(el.get("lon")), to_float(vals.get("ele")),
                                            to_float(vals.get("speed")), to_float(vals.get("hAcc"))))
                el.clear()
        if len(self.route_rows) >= BATCH:
            self.flush()

    def me(self, el) -> None:
        names = {"HKCharacteristicTypeIdentifierDateOfBirth": "date_of_birth",
                 "HKCharacteristicTypeIdentifierBiologicalSex": "biological_sex",
                 "HKCharacteristicTypeIdentifierBloodType": "blood_type",
                 "HKCharacteristicTypeIdentifierFitzpatrickSkinType": "skin_type"}
        rows = []
        for k, v in el.attrib.items():
            key = names.get(k) or label_for_identifier(k)
            rows.append((key, label_for_identifier(v) if v.startswith("HK") else v))
        self.conn.executemany("INSERT OR REPLACE INTO characteristics(key, value) VALUES (?, ?)", rows)

    def activity_summary(self, el) -> None:
        from datetime import datetime, timedelta
        from zoneinfo import ZoneInfo
        a = dict(el.attrib)
        day = a.pop("dateComponents", None)
        if not day:
            return
        tz = ZoneInfo(self.tz_name)
        d0 = datetime.fromisoformat(day).replace(tzinfo=tz)
        start, end = d0.timestamp(), (d0 + timedelta(days=1)).timestamp()
        self.add_sample("HKActivitySummaryType", "activity_summary", None, day, None, start, end,
                        None, None, None, {snake(k): v for k, v in a.items()})

    def correlation(self, el) -> None:
        # Nested <Record>s were already imported on their own end events.
        self.correlations += 1

    def ecg_files(self) -> int:
        if not self.root:
            return 0
        n = 0
        for f in sorted((self.root / "electrocardiograms").glob("*.csv")):
            meta, volts = {}, []
            with f.open(newline="", encoding="utf-8", errors="replace") as fh:
                for row in csv.reader(fh):
                    if not row:
                        continue
                    if len(row) >= 2 and to_float(row[0]) is None:
                        meta[row[0]] = row[1]
                    elif to_float(row[0]) is not None:
                        volts.append(float(row[0]))
            rec = meta.get("Recorded Date")
            try:
                start = parse_date(rec) if rec else f.stat().st_mtime
            except ValueError:
                start = f.stat().st_mtime
            hz = to_float((meta.get("Sample Rate") or "").split()[0] if meta.get("Sample Rate") else None) or 512.0
            meta["voltages_uV"] = volts
            self.add_sample("HKElectrocardiogramType", "electrocardiogram", float(len(volts)),
                            meta.get("Classification"), "uV", start, start + len(volts) / hz,
                            meta.get("Device"), None, None, meta)
            n += 1
        return n

    # -- main loop

    def run(self, xml_path: Path) -> None:
        handlers = {"Record": self.record, "Workout": self.workout, "Me": self.me,
                    "ActivitySummary": self.activity_summary, "Correlation": self.correlation}
        depth = 0
        root = None
        for event, el in iterparse(xml_path, events=("start", "end")):
            if event == "start":
                if root is None:
                    root = el
                depth += 1
                continue
            depth -= 1
            h = handlers.get(el.tag)
            if h and (depth == 1 or el.tag == "Record"):
                h(el)
            if depth == 1:
                # Top-level element finished: free it and detach it from the root.
                el.clear()
                root.clear()
        self.flush()


# ---------------------------------------------------------------- report / csv

def write_report(path: Path, conn: sqlite3.Connection, imp: Importer, info: dict) -> None:
    lines = ["# Health export import report", "",
             f"- Run: {time.strftime('%Y-%m-%d %H:%M:%S')}  ({info['seconds']:.1f} s)",
             f"- export.xml: {info['xml_size']:,} bytes; zip: {info.get('zip_size', 0):,} bytes; "
             f"database: {info['db_size']:,} bytes",
             f"- Records seen this run: {imp.stats['records_seen']:,}; inserted: {imp.stats['inserted']:,}; "
             f"already present / duplicates: {imp.stats['duplicates']:,}",
             f"- Route points inserted: {imp.stats['route_points_inserted']:,}",
             f"- ECG files: {info['ecg']}; correlations seen: {imp.correlations}; "
             f"clinical records (export_cda.xml, not imported): {info['cda']}",
             "", "## Rows per label (whole database)", "",
             "| label | rows | first | last |", "| --- | ---: | --- | --- |"]
    for label, n, lo, hi in conn.execute(
            "SELECT label, COUNT(*), MIN(start_ts), MAX(end_ts) FROM processed_samples GROUP BY label ORDER BY label"):
        f = lambda t: time.strftime("%Y-%m-%d", time.gmtime(t))  # noqa: E731
        lines.append(f"| {label} | {n:,} | {f(lo)} | {f(hi)} |")
    lines += ["", "## Sources", ""] + [f"- {s}: {n:,}" for s, n in sorted(imp.sources.items(), key=lambda x: -x[1])]
    lines += ["", "## Devices", ""] + [f"- {d}: {n:,}" for d, n in sorted(imp.devices.items(), key=lambda x: -x[1])]
    lines += ["", "## Warnings", ""]
    w = imp.warnings + [f"unknown type {t} ({n} records)" for t, n in imp.unknown_types.items()]
    if imp.stats["unparseable"]:
        w.append(f"{imp.stats['unparseable']} unparseable records")
    lines += [f"- {x}" for x in w] or ["- none"]
    path.write_text("\n".join(lines) + "\n")


def write_csvs(conn: sqlite3.Connection, out: Path) -> int:
    out.mkdir(parents=True, exist_ok=True)
    cols = ["hk_uuid", "hk_type", "label", "value", "value_text", "unit", "start_ts", "end_ts",
            "minute_id", "source_name", "device", "metadata_json"]
    labels = [r[0] for r in conn.execute("SELECT DISTINCT label FROM processed_samples ORDER BY label")]
    for label in labels:
        with (out / f"{label}.csv").open("w", newline="") as fh:
            w = csv.writer(fh)
            w.writerow(cols)
            w.writerows(conn.execute(f"SELECT {','.join(cols)} FROM processed_samples WHERE label=? "
                                     "ORDER BY start_ts", (label,)))
    return len(labels)


def extract(zip_path: Path, dest_parent: Path) -> Path:
    """Unzip next to the zip (never modifying it); skipped if already extracted from this zip."""
    target = dest_parent / "apple_health_export"
    marker = target / ".extracted_from"
    stamp = f"{zip_path.stat().st_size}:{int(zip_path.stat().st_mtime)}"
    if marker.exists() and marker.read_text() == stamp:
        return target
    with zipfile.ZipFile(zip_path) as z:
        for m in z.infolist():
            name = m.filename
            if name.startswith("apple_health_export/") and ".." not in Path(name).parts:
                z.extract(m, dest_parent)
    marker.write_text(stamp)
    return target


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dir", type=Path, default=DEFAULT_DIR, help="folder holding export.zip")
    p.add_argument("--xml", type=Path, help="parse this export.xml directly (skips unzip)")
    p.add_argument("--db", type=Path, help="output SQLite (default <dir>/fengshui_health.sqlite)")
    p.add_argument("--report", type=Path, help="report path (default <dir>/import_report.md)")
    p.add_argument("--csv", action="store_true", help="also write one CSV per label to <dir>/csv/")
    p.add_argument("--tz", default=os.environ.get("FENGSHUI_TZ", "America/New_York"),
                   help="IANA zone for ActivitySummary day boundaries")
    args = p.parse_args(argv)

    t0 = time.time()
    info: dict = {"cda": 0}
    if args.xml:
        xml, root = args.xml, args.xml.parent
    else:
        zp = args.dir / "export.zip"
        if not zp.exists():
            print(f"no export at {zp}", file=sys.stderr)
            return 2
        info["zip_size"] = zp.stat().st_size
        root = extract(zp, args.dir)
        xml = root / "export.xml"
    cda = root / "export_cda.xml"
    if cda.exists():
        info["cda"] = sum(1 for _, el in iterparse(cda) if el.tag.endswith("ClinicalDocument") or el.clear())

    out_dir = args.dir if not args.xml else (args.db.parent if args.db else root)
    db_path = args.db or out_dir / "fengshui_health.sqlite"
    conn = fdb.create(str(db_path))
    imp = Importer(conn, root, args.tz)
    imp.run(xml)
    info["ecg"] = imp.ecg_files()
    imp.flush()
    conn.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    info.update(seconds=time.time() - t0, xml_size=xml.stat().st_size, db_size=db_path.stat().st_size)
    write_report(args.report or out_dir / "import_report.md", conn, imp, info)
    if args.csv:
        n = write_csvs(conn, out_dir / "csv")
        print(f"wrote {n} CSV files")
    print(f"imported {imp.stats['inserted']:,} new rows ({imp.stats['duplicates']:,} already present) "
          f"in {info['seconds']:.1f} s → {db_path}")
    conn.close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
