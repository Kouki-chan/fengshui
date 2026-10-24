import json
import zlib

import pytest

from conftest import FIXTURES
from fengshui_engine import raw
from make_raw_vectors import to_chunk, vectors

RAW = FIXTURES / "raw"
VECTORS = json.loads((RAW / "vectors.json").read_text())


def test_checked_in_vectors_are_current():
    # If this fails, re-run make_raw_vectors.py (and the Swift fixture test).
    assert VECTORS == json.loads(json.dumps(vectors()))


@pytest.mark.parametrize("d", VECTORS, ids=lambda d: d["name"])
def test_round_trip(d):
    chunk = to_chunk(d)
    back = raw.decode(raw.encode(chunk))
    assert back.samples == chunk.samples
    assert back.gaps == chunk.gaps
    assert back.sensor == chunk.sensor
    assert back.start_ts == chunk.start_ts
    assert back.rate_hz == pytest.approx(chunk.rate_hz, rel=1e-6)  # stored as f32


@pytest.mark.parametrize("d", VECTORS, ids=lambda d: d["name"])
def test_pack_matches_fixture_bytes(d):
    assert raw.pack(to_chunk(d)) == (RAW / f"{d['name']}.fsr1").read_bytes()


@pytest.mark.parametrize("d", VECTORS, ids=lambda d: d["name"])
def test_swift_encoded_fixtures_decode_exactly(d):
    """Apple COMPRESSION_ZLIB output → zlib.decompress(data, -15) → identical samples."""
    path = RAW / "swift" / f"{d['name']}.bin"
    if not path.exists():
        pytest.fail(f"missing Swift fixture {path}; run `swift test` in apple/FengshuiKit")
    data = path.read_bytes()
    assert zlib.decompress(data, -15) == (RAW / f"{d['name']}.fsr1").read_bytes()
    back = raw.decode(data)
    assert back.samples == [tuple(s) for s in d["samples"]]
    assert back.gaps == [tuple(g) for g in d["gaps"]]


def test_wrapping_deltas_are_lossless():
    d = next(v for v in VECTORS if v["name"] == "accel_wrap")
    assert raw.decode(raw.encode(to_chunk(d))).samples == [tuple(s) for s in d["samples"]]


def test_quantize_rounds_half_away_from_zero_and_clamps():
    assert raw.quantize("accel", [(0.5 / 2048, -0.5 / 2048, 100.0)]) == [(1, -1, 32767)]
    assert raw.quantize("baro", [(101.3255,)]) == [(1326,)]


def test_bad_inputs_raise():
    with pytest.raises(raw.RawFormatError):
        raw.unpack(b"XXXX" + bytes(30))
    good = raw.pack(to_chunk(VECTORS[0]))
    with pytest.raises(raw.RawFormatError):
        raw.unpack(good[:-2])


def test_physical_values():
    c = raw.RawChunk("baro", 0.0, 25.0, [(1325,)])
    assert c.physical()[0][0] == pytest.approx(101.325)
