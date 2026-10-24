"""HealthKit identifier → snake_case label (spec §6.1). Reference implementation;
the Swift `LabelMapper` must agree (checked against fixtures/hk_labels.json)."""

from __future__ import annotations

import re
from functools import lru_cache

# Longest first so e.g. "HKCategoryTypeIdentifier" wins over shorter prefixes.
_PREFIXES = (
    "HKQuantityTypeIdentifier", "HKCategoryTypeIdentifier", "HKCorrelationTypeIdentifier",
    "HKCharacteristicTypeIdentifier", "HKDocumentTypeIdentifier", "HKScoredAssessmentTypeIdentifier",
    "HKDataTypeIdentifier", "HKDataType",
    "HKWorkoutActivityType", "HKCategoryValue", "HKBiologicalSex", "HKBloodType",
    "HKFitzpatrickSkinType", "HKWheelchairUse", "HK",
)
_SPECIAL = {
    "HKWorkoutTypeIdentifier": "workout",
    "HKWorkoutRouteTypeIdentifier": "workout_route",
    "HKDataTypeIdentifierHeartbeatSeries": "heartbeat_series",
    "HKElectrocardiogramType": "electrocardiogram",
    "HKAudiogramSampleType": "audiogram",
    "HKAudiogramTypeIdentifier": "audiogram",
    "HKStateOfMindTypeIdentifier": "state_of_mind",
    "HKVisionPrescriptionTypeIdentifier": "vision_prescription",
}
_A = re.compile(r"([a-z0-9])([A-Z])")      # fooBar -> foo_Bar, vo2Max handled by digits rule
_B = re.compile(r"([A-Z]+)([A-Z][a-z])")   # SDNNValue -> SDNN_Value, UVExposure -> UV_Exposure


def snake(name: str) -> str:
    return _A.sub(r"\1_\2", _B.sub(r"\1_\2", name)).lower()


@lru_cache(maxsize=None)
def label_for_identifier(identifier: str) -> str:
    if identifier in _SPECIAL:
        return _SPECIAL[identifier]
    for p in _PREFIXES:
        if identifier.startswith(p) and len(identifier) > len(p):
            return snake(identifier[len(p):])
    return snake(identifier)


@lru_cache(maxsize=None)
def category_value_text(hk_type: str, value: str) -> str:
    """'HKCategoryValueSleepAnalysisAsleepCore' → 'asleep_core'.

    Strips the generic prefix, then the type's own name when the enum repeats it
    (SleepAnalysis…, AppleStandHour…), else keeps the enum family (severity_moderate)."""
    if not value.startswith("HKCategoryValue"):
        return snake(value)
    rest = value[len("HKCategoryValue"):]
    type_name = hk_type
    for p in _PREFIXES:
        if type_name.startswith(p):
            type_name = type_name[len(p):]
            break
    if rest.startswith(type_name) and len(rest) > len(type_name):
        rest = rest[len(type_name):]
    return snake(rest)


# Raw values HealthKit uses for sleep analysis (HKCategoryValueSleepAnalysis).
SLEEP_RAW = {"in_bed": 0, "asleep_unspecified": 1, "awake": 2,
             "asleep_core": 3, "asleep_deep": 4, "asleep_rem": 5}
SLEEP_ASLEEP = frozenset({"asleep_unspecified", "asleep_core", "asleep_deep", "asleep_rem"})
