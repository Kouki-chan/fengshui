"""Raw chunk codec `fsr1-i16-delta-deflate` (spec §7.3).

One chunk = one sensor, one minute. Layout before compression, little-endian:
magic 'FSR1', version u8, sensor_code u8, axes u8, reserved u8, start_ts f64,
rate_hz f32, n_samples u32, n_gaps u16, gaps n×(u32 index, u32 missing),
first axes×i16, deltas (n-1)×axes×i16 with wrapping arithmetic.

Compression is raw DEFLATE (no zlib header), which is what Apple's
COMPRESSION_ZLIB produces, hence wbits = -15.
"""

from __future__ import annotations

import math
import struct
import zlib
from dataclasses import dataclass, field

ENCODING = "fsr1-i16-delta-deflate"
MAGIC = b"FSR1"
FORMAT_VERSION = 1

SENSOR_CODES = {"accel": 1, "gyro": 2, "baro": 3, "compass": 4, "hr_session": 5}
SENSOR_NAMES = {v: k for k, v in SENSOR_CODES.items()}
SENSOR_AXES = {"accel": 3, "gyro": 3, "baro": 1, "compass": 1, "hr_session": 1}

# physical = int * scale + offset
SENSOR_SCALE = {
    "accel": (1 / 2048, 0.0),      # g, ±16 g
    "gyro": (0.001, 0.0),          # rad/s
    "baro": (0.001, 100.0),        # kPa
    "compass": (0.02, 0.0),        # degrees
    "hr_session": (0.1, 0.0),      # bpm
}

_HEADER = struct.Struct("<4sBBBBdfIH")
_GAP = struct.Struct("<II")


class RawFormatError(ValueError):
    pass


@dataclass
class RawChunk:
    sensor: str
    start_ts: float
    rate_hz: float
    samples: list[tuple[int, ...]]           # quantized ints, one tuple per sample
    gaps: list[tuple[int, int]] = field(default_factory=list)

    @property
    def axes(self) -> int:
        return SENSOR_AXES[self.sensor]

    @property
    def scale(self) -> float:
        return SENSOR_SCALE[self.sensor][0]

    @property
    def offset(self) -> float:
        return SENSOR_SCALE[self.sensor][1]

    def physical(self) -> list[tuple[float, ...]]:
        s, o = self.scale, self.offset
        return [tuple(v * s + o for v in row) for row in self.samples]


def _wrap16(v: int) -> int:
    """Map any int to signed int16 range with two's-complement wrapping."""
    v &= 0xFFFF
    return v - 0x10000 if v >= 0x8000 else v


def quantize(sensor: str, values: list[tuple[float, ...]]) -> list[tuple[int, ...]]:
    """Physical → int16, rounding half away from zero and clamping to int16
    (same as Swift's `Int16(clamping: (x).rounded())`)."""
    scale, offset = SENSOR_SCALE[sensor]
    out = []
    for row in values:
        q = []
        for x in row:
            r = (x - offset) / scale
            r = math.floor(r + 0.5) if r >= 0 else -math.floor(-r + 0.5)
            q.append(max(-32768, min(32767, int(r))))
        out.append(tuple(q))
    return out


def pack(chunk: RawChunk) -> bytes:
    """Uncompressed FSR1 bytes."""
    axes = chunk.axes
    n = len(chunk.samples)
    parts = [_HEADER.pack(MAGIC, FORMAT_VERSION, SENSOR_CODES[chunk.sensor], axes, 0,
                          chunk.start_ts, chunk.rate_hz, n, len(chunk.gaps))]
    parts += [_GAP.pack(i, m) for i, m in chunk.gaps]
    if n:
        vals = list(chunk.samples[0])
        prev = chunk.samples[0]
        for row in chunk.samples[1:]:
            vals.extend(_wrap16(c - p) for c, p in zip(row, prev))
            prev = row
        parts.append(struct.pack(f"<{len(vals)}h", *vals))
    return b"".join(parts)


def unpack(data: bytes) -> RawChunk:
    if len(data) < _HEADER.size:
        raise RawFormatError("chunk too short")
    magic, ver, code, axes, _res, start_ts, rate, n, n_gaps = _HEADER.unpack_from(data, 0)
    if magic != MAGIC:
        raise RawFormatError(f"bad magic {magic!r}")
    if ver != FORMAT_VERSION:
        raise RawFormatError(f"unsupported version {ver}")
    if code not in SENSOR_NAMES:
        raise RawFormatError(f"unknown sensor code {code}")
    sensor = SENSOR_NAMES[code]
    if axes != SENSOR_AXES[sensor]:
        raise RawFormatError(f"axes {axes} != expected {SENSOR_AXES[sensor]} for {sensor}")
    pos = _HEADER.size
    gaps = []
    for _ in range(n_gaps):
        gaps.append(_GAP.unpack_from(data, pos))
        pos += _GAP.size
    count = n * axes
    if len(data) - pos != count * 2:
        raise RawFormatError(f"payload size {len(data) - pos} != {count * 2}")
    vals = struct.unpack_from(f"<{count}h", data, pos) if count else ()
    samples: list[tuple[int, ...]] = []
    if n:
        prev = list(vals[:axes])
        samples.append(tuple(prev))
        for i in range(1, n):
            base = i * axes
            prev = [_wrap16(p + d) for p, d in zip(prev, vals[base:base + axes])]
            samples.append(tuple(prev))
    return RawChunk(sensor=sensor, start_ts=start_ts, rate_hz=rate, samples=samples,
                    gaps=[tuple(g) for g in gaps])


def encode(chunk: RawChunk) -> bytes:
    """FSR1 bytes compressed as raw DEFLATE (interoperable with Apple COMPRESSION_ZLIB)."""
    c = zlib.compressobj(level=6, wbits=-15)
    return c.compress(pack(chunk)) + c.flush()


def decode(payload: bytes) -> RawChunk:
    return unpack(zlib.decompress(payload, -15))
