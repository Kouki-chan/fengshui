#!/usr/bin/env python3
"""Generate the HealthKit type catalog from the SDK headers that ship with Xcode.

Swift can't enumerate HKQuantityTypeIdentifier values at runtime, so the list is
built from the SDK headers here (once per Xcode update) into:
  fixtures/hk_identifiers_ios26.json      identifiers available on iOS ≤ 26, with label + default unit
  apple/Fengshui/Health/HealthTypeCatalog+Generated.swift

    .venv/bin/python scripts/gen_hk_catalog.py
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "engine"))
from fengshui_engine.hk_labels import label_for_identifier  # noqa: E402

MAX_IOS = (26, 0)
KINDS = {"HKQuantityTypeIdentifier": "quantity", "HKCategoryTypeIdentifier": "category",
         "HKCharacteristicTypeIdentifier": "characteristic", "HKCorrelationTypeIdentifier": "correlation",
         "HKScoredAssessmentTypeIdentifier": "scored_assessment", "HKDocumentTypeIdentifier": "document"}
# Special object types requested through dedicated HKObjectType accessors.
SPECIAL = {"HKWorkoutTypeIdentifier": "workout", "HKWorkoutRouteTypeIdentifier": "series",
           "HKDataTypeIdentifierHeartbeatSeries": "series", "HKDataTypeIdentifierStateOfMind": "state_of_mind",
           "HKAudiogramSampleType": "audiogram", "HKElectrocardiogramType": "electrocardiogram"}
# Excluded on purpose (DECISIONS D-10).
EXCLUDED = {"HKDocumentTypeIdentifierCDA": "clinical document (needs the health-records entitlement)",
            "HKMedicationDoseEventTypeIdentifierMedicationDoseEvent": "needs per-object medication authorization",
            "HKDataTypeIdentifierUserAnnotatedMedicationConcept": "needs per-object medication authorization",
            "HKVisionPrescriptionTypeIdentifier": "needs per-object authorization"}

LINE = re.compile(r"HK_EXTERN\s+(\w+)\s*(?:\*\s*)?const\s+(\w+)\s+(API_[A-Z_]+\((?:[^()]|\([^()]*\))*\))(?:\s*;)?\s*(?://\s*(.*))?")


def ios_since(avail: str) -> tuple[int, int] | None:
    m = re.search(r"ios\((\d+)\.(\d+)", avail) or re.search(r"ios\((\d+)_(\d+)", avail)
    return (int(m.group(1)), int(m.group(2))) if m else None


def main() -> None:
    sdk = subprocess.check_output(["xcrun", "--sdk", "iphoneos", "--show-sdk-path"], text=True).strip()
    hdr = Path(sdk) / "System/Library/Frameworks/HealthKit.framework/Headers"
    out, excluded, newer = [], [], []
    seen = set()
    for h in sorted(hdr.glob("*.h")):
        for line in h.read_text().splitlines():
            m = LINE.search(line)
            if not m:
                continue
            ctype, ident, avail, comment = m.groups()
            kind = next((v for k, v in KINDS.items() if ident.startswith(k) and ctype != "NSString"), None) \
                or next((v for k, v in KINDS.items() if ctype == k), None) or SPECIAL.get(ident)
            if not kind or ident in seen:
                continue
            seen.add(ident)
            since = ios_since(avail)
            if since is None or "API_UNAVAILABLE(ios" in line:
                continue
            if "API_DEPRECATED" in avail and "ios(" in avail and re.search(r"ios\(\d+\.\d+,\s*\d+", avail):
                excluded.append({"identifier": ident, "reason": "deprecated on iOS"})
                continue
            if since > MAX_IOS:
                newer.append(ident)
                continue
            if ident in EXCLUDED:
                excluded.append({"identifier": ident, "reason": EXCLUDED[ident]})
                continue
            unit = None
            if kind == "quantity" and comment:
                unit = comment.split(",")[0].strip() or None
            out.append({"identifier": ident, "kind": kind, "ios": f"{since[0]}.{since[1]}",
                        "label": label_for_identifier(ident), "default_unit": unit,
                        "aggregation": (comment.split(",", 1)[1].strip() if kind == "quantity" and comment
                                        and "," in comment else None)})
    for ident, kind in (("HKAudiogramSampleType", "audiogram"), ("HKElectrocardiogramType", "electrocardiogram")):
        out.append({"identifier": ident, "kind": kind, "ios": "13.0" if kind == "audiogram" else "14.0",
                    "label": label_for_identifier(ident), "default_unit": None, "aggregation": None})
    out.sort(key=lambda d: (d["kind"], d["identifier"]))
    (ROOT / "fixtures" / "hk_identifiers_ios26.json").write_text(json.dumps(
        {"sdk": Path(sdk).name, "max_ios": "26.0", "types": out, "excluded": excluded,
         "newer_than_ios26": sorted(newer)}, indent=1) + "\n")
    write_swift(out)
    by_kind: dict[str, int] = {}
    for d in out:
        by_kind[d["kind"]] = by_kind.get(d["kind"], 0) + 1
    print(f"{len(out)} types {by_kind}; excluded {len(excluded)}; newer than iOS 26: {len(newer)}")


def write_swift(types: list[dict]) -> None:
    rows = []
    for d in types:
        unit = f'"{d["default_unit"]}"' if d["default_unit"] else "nil"
        rows.append(f'        .init(identifier: "{d["identifier"]}", kind: .{camel(d["kind"])}, '
                    f'label: "{d["label"]}", defaultUnit: {unit}),')
    src = ("// GENERATED by scripts/gen_hk_catalog.py from the Xcode SDK headers. Do not edit.\n\n"
           "extension HealthTypeCatalog {\n"
           "    /// Every HealthKit object type available on iOS ≤ 26 that Fengshui reads.\n"
           "    static let all: [HealthTypeInfo] = [\n" + "\n".join(rows) + "\n    ]\n}\n")
    p = ROOT / "apple" / "Fengshui" / "Health" / "HealthTypeCatalog+Generated.swift"
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_text(src)


def camel(s: str) -> str:
    a, *rest = s.split("_")
    return a + "".join(x.title() for x in rest)


if __name__ == "__main__":
    main()
