"""Task `place_suggestions` (spec §6.2): cluster visits that matched no named place.

Greedy clustering in arrival order: a visit joins the nearest cluster whose
centroid is within SUGGEST_CLUSTER_RADIUS_M, else starts one. Clusters with
≥ SUGGEST_MIN_VISITS visits become `context_places` rows (kind 'suggested',
confirmed 0) unless an existing place, a pending suggestion, or a dismissed
location already covers them.
"""

from __future__ import annotations

import json
import math
import sqlite3

from . import config as C

EARTH_R_M = 6_371_000.0


def haversine_m(lat1: float, lon1: float, lat2: float, lon2: float) -> float:
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp, dl = p2 - p1, math.radians(lon2 - lon1)
    a = math.sin(dp / 2) ** 2 + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    return 2 * EARTH_R_M * math.asin(math.sqrt(a))


def cluster(points: list[tuple[float, float]], radius_m: float) -> list[list[int]]:
    """Indices of `points` grouped into clusters (greedy, deterministic)."""
    clusters: list[dict] = []
    for i, (lat, lon) in enumerate(points):
        best, best_d = None, radius_m
        for c in clusters:
            d = haversine_m(lat, lon, c["lat"], c["lon"])
            if d <= best_d:
                best, best_d = c, d
        if best is None:
            clusters.append({"lat": lat, "lon": lon, "members": [i]})
        else:
            best["members"].append(i)
            n = len(best["members"])
            best["lat"] += (lat - best["lat"]) / n
            best["lon"] += (lon - best["lon"]) / n
    return [c["members"] for c in clusters]


def run(conn: sqlite3.Connection, ctx: dict) -> dict:
    since = ctx["now_ts"] - C.SUGGEST_LOOKBACK_DAYS * 86400
    visits = conn.execute(
        "SELECT lat, lon, arrival_ts, departure_ts FROM context_visits "
        "WHERE place_id IS NULL AND arrival_ts >= ? ORDER BY arrival_ts", (since,)).fetchall()
    pts = [(v[0], v[1]) for v in visits
           if v[3] is None or (v[3] - v[2]) >= C.SUGGEST_MIN_VISIT_MIN * 60]
    places = conn.execute("SELECT lat, lon, radius_m FROM context_places").fetchall()
    row = conn.execute("SELECT value_json FROM preferences WHERE key = 'dismissed_places'").fetchone()
    dismissed = json.loads(row[0]) if row else []

    written = 0
    for members in cluster(pts, C.SUGGEST_CLUSTER_RADIUS_M):
        if len(members) < C.SUGGEST_MIN_VISITS:
            continue
        lat = sum(pts[i][0] for i in members) / len(members)
        lon = sum(pts[i][1] for i in members) / len(members)
        if any(haversine_m(lat, lon, p[0], p[1]) <= max(p[2], C.SUGGEST_CLUSTER_RADIUS_M) for p in places):
            continue
        if any(haversine_m(lat, lon, d[0], d[1]) <= C.SUGGEST_CLUSTER_RADIUS_M for d in dismissed):
            continue
        conn.execute(
            "INSERT INTO context_places (name, kind, lat, lon, radius_m, confirmed, created_at) "
            "VALUES (?, 'suggested', ?, ?, ?, 0, ?)",
            (f"Place visited {len(members)}×", round(lat, 6), round(lon, 6), C.PLACE_DEFAULT_RADIUS_M, ctx["now_ts"]))
        places.append((lat, lon, C.PLACE_DEFAULT_RADIUS_M))
        written += 1
    return {"rows_written": written, "unmatched_visits": len(pts)}
