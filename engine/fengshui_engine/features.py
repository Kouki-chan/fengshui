"""Task `features` (spec §10.1 step 1): raw_chunks → raw_minute_features.

Per minute, from the accelerometer (tier 1, else tier 3):
  enmo_mg      mean over samples of max(|a| − 1 g, 0), in milli-g
  mag_sd_mg    standard deviation of |a|, milli-g
  cadence_hz   dominant periodicity of |a| in 0.5–3.5 Hz: autocorrelation over 10 s
               windows, median across windows, NULL if the peak correlation < 0.3
  active_frac  share of 5 s epochs whose mean enmo > 45 mg
and, when snapshots / sessions exist: pressure, vertical speed, heading change, gyro RMS.

Incremental: a minute is (re)computed when it has no feature row yet, or a chunk for
it arrived after its row was computed.
"""

from __future__ import annotations

import math
import sqlite3
import statistics

from . import config as C
from . import raw


def _magnitudes(chunk: raw.RawChunk) -> list[float]:
    s = chunk.scale
    return [math.sqrt((x * s) ** 2 + (y * s) ** 2 + (z * s) ** 2) for x, y, z in chunk.samples]


def cadence_hz(mag: list[float], rate: float) -> float | None:
    """Median over 10 s windows of the autocorrelation peak frequency (0.5–3.5 Hz)."""
    step = max(1, round(rate / C.CADENCE_RATE_HZ))
    x = mag[::step]
    r = rate / step
    win = int(C.CADENCE_WINDOW_S * r)
    lag_lo = max(2, int(r / C.CADENCE_MAX_HZ))
    lag_hi = int(r / C.CADENCE_MIN_HZ)
    freqs = []
    for w0 in range(0, len(x) - win + 1, win):
        seg = x[w0:w0 + win]
        mu = sum(seg) / win
        d = [v - mu for v in seg]
        energy = sum(v * v for v in d)
        if energy <= 1e-12:
            continue
        corr = []
        for lag in range(lag_lo, min(lag_hi, win - 1) + 1):
            corr.append(sum(d[i] * d[i + lag] for i in range(win - lag)) / energy)
        # First local maximum above the threshold = fundamental (avoids picking 2× the period).
        best = None
        for k in range(1, len(corr) - 1):
            if corr[k] >= C.CADENCE_MIN_CORR and corr[k] >= corr[k - 1] and corr[k] >= corr[k + 1]:
                best = k
                break
        if best is None:
            continue
        # Parabolic interpolation for sub-sample lag resolution.
        a, b, c = corr[best - 1], corr[best], corr[best + 1]
        den = a - 2 * b + c
        off = 0.5 * (a - c) / den if den else 0.0
        freqs.append(r / (lag_lo + best + off))
    return round(statistics.median(freqs), 3) if freqs else None


def accel_features(chunk: raw.RawChunk) -> dict:
    mag = _magnitudes(chunk)
    n = len(mag)
    if n == 0:
        return {"accel_samples": 0}
    enmo = [max(m - 1.0, 0.0) * 1000 for m in mag]
    sd = statistics.pstdev(mag) * 1000 if n > 1 else 0.0
    rate = chunk.rate_hz
    epoch = max(1, int(C.EPOCH_S * rate))
    epochs = [enmo[i:i + epoch] for i in range(0, n, epoch)]
    active = sum(1 for e in epochs if sum(e) / len(e) > C.ENMO_LIGHT_MG) / len(epochs)
    cad = cadence_hz(mag, rate) if sd >= C.CADENCE_MIN_SD_MG else None
    return {"accel_samples": n, "enmo_mg": round(sum(enmo) / n, 3), "mag_sd_mg": round(sd, 3),
            "cadence_hz": cad, "active_frac": round(active, 4)}


def _linfit_slope(ts: list[float], ys: list[float]) -> float | None:
    if len(ts) < 2 or max(ts) - min(ts) < 1.0:
        return None
    mt, my = sum(ts) / len(ts), sum(ys) / len(ys)
    den = sum((t - mt) ** 2 for t in ts)
    return sum((t - mt) * (y - my) for t, y in zip(ts, ys)) / den if den else None


def _timestamps(chunk: raw.RawChunk) -> list[float]:
    """Sample times, honouring recorded gaps."""
    out, i, extra = [], 0, 0
    gaps = dict(chunk.gaps)
    for k in range(len(chunk.samples)):
        extra += gaps.get(k, 0)
        out.append(chunk.start_ts + (k + extra) / chunk.rate_hz)
        i += 1
    return out


def run(conn: sqlite3.Connection, ctx: dict) -> dict:
    todo = [r[0] for r in conn.execute(
        """SELECT DISTINCT c.minute_id FROM raw_chunks c
           LEFT JOIN raw_minute_features f ON f.minute_id = c.minute_id
           WHERE c.payload IS NOT NULL AND (f.minute_id IS NULL OR c.received_at > f.computed_at)
           ORDER BY c.minute_id LIMIT ?""", (C.FEATURES_MAX_MINUTES_PER_RUN,))]
    if not todo:
        return {"rows_written": 0}
    lo, hi = todo[0] - C.BARO_FIT_WINDOW_MIN, todo[-1] + C.BARO_FIT_WINDOW_MIN
    # Barometer samples around the batch, for the ± 2-minute vertical-speed fit.
    baro: dict[int, list[tuple[float, float]]] = {}
    for mid, payload in conn.execute(
            "SELECT minute_id, payload FROM raw_chunks WHERE sensor='baro' AND payload IS NOT NULL "
            "AND minute_id BETWEEN ? AND ? ORDER BY tier", (lo, hi)):
        c = raw.decode(payload)
        baro.setdefault(mid, []).extend(zip(_timestamps(c), (v[0] for v in c.physical())))

    written = 0
    for mid in todo:
        chunks = {(r[0], r[1]): r[2] for r in conn.execute(
            "SELECT sensor, tier, payload FROM raw_chunks WHERE minute_id=? AND payload IS NOT NULL", (mid,))}
        row: dict = {}
        accel = chunks.get(("accel", 1)) or chunks.get(("accel", 3))
        if accel:
            row.update(accel_features(raw.decode(accel)))
        near = [p for m in range(mid - C.BARO_FIT_WINDOW_MIN, mid + C.BARO_FIT_WINDOW_MIN + 1) for p in baro.get(m, [])]
        if baro.get(mid):
            row["pressure_kpa"] = round(sum(p for _, p in baro[mid]) / len(baro[mid]), 5)
            slope = _linfit_slope([t for t, _ in near], [-(p * 10) * C.BARO_M_PER_HPA for _, p in near])  # m/s
            row["vert_speed_m_min"] = round(slope * 60, 3) if slope is not None else None
        comp = chunks.get(("compass", 3)) or chunks.get(("compass", 2))
        if comp:
            h = [v[0] for v in raw.decode(comp).physical()]
            row["heading_change_deg"] = round(sum(abs((b - a + 180) % 360 - 180) for a, b in zip(h, h[1:])), 2)
        gyro = chunks.get(("gyro", 3)) or chunks.get(("gyro", 2))
        if gyro:
            g = raw.decode(gyro).physical()
            if g:
                row["gyro_rms_dps"] = round(math.degrees(math.sqrt(sum(x * x + y * y + z * z for x, y, z in g) / len(g))), 3)
        conn.execute(
            """INSERT INTO raw_minute_features (minute_id, accel_samples, enmo_mg, mag_sd_mg, cadence_hz, active_frac,
                 pressure_kpa, vert_speed_m_min, heading_change_deg, gyro_rms_dps, feature_version, computed_at)
               VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
               ON CONFLICT(minute_id) DO UPDATE SET accel_samples=excluded.accel_samples, enmo_mg=excluded.enmo_mg,
                 mag_sd_mg=excluded.mag_sd_mg, cadence_hz=excluded.cadence_hz, active_frac=excluded.active_frac,
                 pressure_kpa=excluded.pressure_kpa, vert_speed_m_min=excluded.vert_speed_m_min,
                 heading_change_deg=excluded.heading_change_deg, gyro_rms_dps=excluded.gyro_rms_dps,
                 feature_version=excluded.feature_version, computed_at=excluded.computed_at""",
            (mid, row.get("accel_samples"), row.get("enmo_mg"), row.get("mag_sd_mg"), row.get("cadence_hz"),
             row.get("active_frac"), row.get("pressure_kpa"), row.get("vert_speed_m_min"),
             row.get("heading_change_deg"), row.get("gyro_rms_dps"), C.FEATURE_VERSION, ctx["now_ts"]))
        written += 1
    return {"rows_written": written, "more": len(todo) == C.FEATURES_MAX_MINUTES_PER_RUN}
