"""The shared time key. Must match FengshuiKit.MinuteID exactly."""

import math


def minute_id(unix_seconds_utc: float) -> int:
    """floor(unix_seconds / 60). floor (not int()) so pre-1970 values round down too."""
    return math.floor(unix_seconds_utc / 60)


def minute_start(mid: int) -> float:
    return mid * 60.0
