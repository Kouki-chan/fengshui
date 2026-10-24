"""Identity of rows imported from an Apple Health export (DECISIONS D-06).

Must match FengshuiKit.ExportKey byte-for-byte (shared vectors in fixtures/export_keys.json).
"""

from __future__ import annotations

import hashlib
import math


def format_value(v: float | None) -> str:
    if v is None:
        return ""
    if v == int(v) and abs(v) < 1e15:
        return str(int(v))
    return repr(float(v))


TIME_TOL_S = 1.0
VALUE_REL_TOL = 1e-3
VALUE_ABS_TOL = 1e-2


def find_export_match(conn, *, label: str, start: float, end: float, source_name: str | None,
                      value: float | None, value_text: str | None) -> int | None:
    """id of the single `export:` row this HealthKit sample corresponds to, else None.
    Tolerant tuple match, see DECISIONS D-06 (mirrors Swift ExportAdoption)."""
    rows = conn.execute(
        "SELECT id, end_ts, source_name, value, value_text FROM processed_samples "
        "WHERE label = ? AND start_ts BETWEEN ? AND ? AND hk_uuid LIKE 'export:%' AND deleted = 0",
        (label, start - TIME_TOL_S, start + TIME_TOL_S)).fetchall()
    hits = []
    for rid, r_end, r_src, r_val, r_txt in rows:
        if abs(r_end - end) > TIME_TOL_S or (r_src or "") != (source_name or ""):
            continue
        if r_txt is not None and value_text is not None and r_txt != value_text:
            continue
        if label != "workout" and r_val is not None and value is not None and \
                abs(r_val - value) > max(VALUE_ABS_TOL, VALUE_REL_TOL * abs(value)):
            continue
        hits.append(rid)
    return hits[0] if len(hits) == 1 else None


def export_key(hk_type: str, start: float, end: float, source_name: str | None,
               value: float | None, value_text: str | None) -> str:
    # Whole seconds: the export has 1 s resolution, HealthKit has sub-second.
    # floor(x + 0.5), not round(): Python's round() is half-to-even, Swift's isn't.
    parts = [hk_type, str(math.floor(start + 0.5)), str(math.floor(end + 0.5)), source_name or "",
             format_value(value), value_text or ""]
    return "export:" + hashlib.sha1("|".join(parts).encode()).hexdigest()
