import json
import os

import pytest

import fengshui_engine
import truth
from conftest import FIXTURES
from fengshui_engine import activity as A
from fengshui_engine import config as C
from fengshui_engine import db
from fengshui_engine.minute import minute_id

GOLDEN = FIXTURES / "golden" / "activity_typical_week.json"


def run(path, sc, now=None, tasks=("features", "activity")):
    return fengshui_engine.run(str(path), now_ts=now or sc["now"], tz=sc["tz"], where="phone", tasks=list(tasks))


def bouts(conn, kind="activity_bout"):
    return [(r[0], r[1], json.loads(r[2]), r[3]) for r in conn.execute(
        "SELECT minute_start, minute_end, value_json, provisional FROM inferences WHERE kind=? "
        "AND superseded_by IS NULL ORDER BY minute_start", (kind,))]


# ---------------------------------------------------------------- unit: smoothing

def test_viterbi_smooths_single_minute_flicker():
    sc = [[0.0] * len(A.LABELS) for _ in range(9)]
    for i in range(9):
        sc[i][A.L["sedentary"]] = 1.0
    # Weak one-minute blip: cheaper to stay than to pay two switch penalties.
    sc[4] = [0.0] * len(A.LABELS)
    sc[4][A.L["walking"]] = 0.5
    sc[4][A.L["sedentary"]] = 0.2
    path = A.viterbi(sc, [None] * 9)
    assert {A.LABELS[p] for p in path} == {"sedentary"}
    # Strong blip (sedentary impossible): Viterbi keeps it, the 2-minute walking minimum removes it.
    sc[4][A.L["walking"]], sc[4][A.L["sedentary"]] = 1.0, 0.0
    path = A.viterbi(sc, [None] * 9)
    assert A.LABELS[path[4]] == "walking"
    class W:  # minimal window stand-in for to_bouts
        workout_id = [None] * 9
    merged = A.enforce_min_lengths(A.to_bouts(path, W), sc)
    assert merged == [["sedentary", 0, 9]]


def test_viterbi_keeps_real_change_and_fixed_overrides():
    k = len(A.LABELS)
    sc = [[0.0] * k for _ in range(10)]
    for i in range(10):
        sc[i][A.L["walking" if i >= 5 else "sedentary"]] = 1.0
    fixed = [None] * 10
    fixed[7] = "workout"
    path = [A.LABELS[p] for p in A.viterbi(sc, fixed)]
    assert path[:5] == ["sedentary"] * 5 and path[7] == "workout" and path[9] == "walking"
    # Fixed labels are never chosen outside overrides.
    sc2 = [[0.0] * k for _ in range(3)]
    assert "workout" not in [A.LABELS[p] for p in A.viterbi(sc2, [None] * 3)]


def test_min_bout_merge_prefers_neighbour_with_higher_score():
    k = len(A.LABELS)
    sc = [[0.0] * k for _ in range(12)]
    for i in range(12):
        sc[i][A.L["sedentary"]] = 0.5
    for i in (5, 6):                      # 2-minute light bout (< 3 min minimum)
        sc[i][A.L["light"]] = 1.0
        sc[i][A.L["walking"]] = 0.7
    b = [["sedentary", 0, 5], ["light", 5, 7], ["walking", 7, 12]]
    out = A.enforce_min_lengths([x[:] for x in b], sc)
    assert out == [["sedentary", 0, 5], ["walking", 5, 12]]   # walking scores higher there than sedentary
    # Overrides never absorb or change.
    out2 = A.enforce_min_lengths([["sleep", 0, 5], ["light", 5, 6], ["sleep", 6, 12]], sc)
    assert out2 == [["sleep", 0, 5], ["light", 5, 6], ["sleep", 6, 12]]


# ---------------------------------------------------------------- scenarios vs ground truth

THRESHOLDS = {  # (all-days accuracy, raw-days accuracy)
    "typical_week": (0.94, 0.98), "no_watch_data": (0.93, 0.90), "shift_worker": (0.97, 0.98), "sparse_data": (0.93, 0.98),
}


@pytest.mark.parametrize("name", THRESHOLDS)
def test_agreement_with_ground_truth(built, tmp_path, name):
    p, sc = built(name, tmp_path)
    run(p, sc)
    conn = db.connect(str(p))
    hi = minute_id(sc["now"])
    acc, conf, rec = truth.agreement(conn, sc, hi - 14 * 1440, hi)
    lo_raw = minute_id(sc["raw_plan"][0][0]) if sc["raw_plan"] else hi - 1440
    acc_raw, _, rec_raw = truth.agreement(conn, sc, lo_raw, hi)
    print(f"METRIC activity_agreement {name} all={acc:.3f} raw_days={acc_raw:.3f}")
    all_min, raw_min = THRESHOLDS[name]
    assert acc >= all_min and acc_raw >= raw_min, (conf.most_common(10), rec)
    for lab in ("walking", "in_vehicle", "sleep", "sedentary"):
        if lab in rec:
            assert rec[lab] >= 0.95, (lab, rec)
    if sc["raw_plan"]:
        assert rec_raw.get("watch_off", 1.0) >= 0.9, rec_raw   # needs accelerometer stillness (spec)


def test_bout_details_typical_week(built, tmp_path):
    p, sc = built("typical_week", tmp_path)
    run(p, sc)
    conn = db.connect(str(p))
    bs = bouts(conn)
    labels = {b[2]["label"] for b in bs}
    assert {"walking", "in_vehicle", "sedentary", "sleep", "workout", "stairs", "watch_off"} <= labels
    runs = [b for b in bs if b[2]["workout_type"] == "running"]
    assert runs and all(b[2]["intensity"] in ("moderate", "vigorous") for b in runs)
    # Lunch walk: left Work and came back → "near Work"; brisk → at least moderate.
    lunch = [b for b in bs if b[2]["label"] == "walking" and b[2]["minutes"] >= 15 and b[2]["place"] == "near Work"]
    assert lunch and all(b[2]["intensity"] in ("moderate", "vigorous") for b in lunch)
    assert all(b[2]["steps"] > 1500 for b in lunch)
    commutes = [b for b in bs if b[2]["label"] == "in_vehicle" and b[2]["minutes"] >= 20]
    assert any(b[2]["from"] == "Home" and b[2]["to"] == "Work" for b in commutes)
    assert any(b[2]["from"] == "Work" and b[2]["to"] == "Home" for b in commutes)
    desk = [b for b in bs if b[2]["label"] == "sedentary" and b[2]["place"] == "at Work"]
    assert desk
    for b in bs:
        v = b[2]
        assert v["minutes"] == b[1] - b[0]
        if v["label"] in C.MIN_BOUT_MIN and b[0] > minute_id(sc["now"]) - 14 * 1440 + 1:
            assert v["minutes"] >= C.MIN_BOUT_MIN[v["label"]] or v["label"] in A.FIXED, v
        assert set(v) == {"label", "intensity", "start", "end", "minutes", "steps", "avg_hr", "place", "from", "to",
                          "workout_type", "sources"}
    assert any("accelerometer" in b[2]["sources"] and "phone_motion" in b[2]["sources"] for b in bs)
    # Confidence in [0, 1]; algorithm/version recorded.
    for r in conn.execute("SELECT confidence, algorithm, algorithm_version FROM inferences WHERE kind='activity_bout'"):
        assert 0 <= r[0] <= 1 and r[1] == "activity" and r[2] == "activity-v1"


def test_days_summary(built, tmp_path):
    p, sc = built("typical_week", tmp_path)
    run(p, sc)
    days = bouts(db.connect(str(p)), "activity_day")
    assert len(days) >= 14
    full = days[-2][2]                          # yesterday: complete day
    assert sum(full["minutes"].values()) == 1440
    assert full["steps"] > 3000 and full["mvpa_minutes"] > 15 and full["longest_sedentary_min"] > 60
    assert 0 < full["coverage_pct"] <= 100
    assert days[-1][3] == 1 and days[-2][3] == 0    # today provisional


def test_incremental_provisional_and_idempotent(built, tmp_path):
    p, sc = built("typical_week", tmp_path)
    s1 = run(p, sc)
    assert run(p, sc)["tasks"]["activity"]["rows_written"] == 0          # identical re-run writes nothing
    conn = db.connect(str(p))
    prov = [b for b in bouts(conn) if b[3] == 1]
    assert prov and all(b[1] > minute_id(sc["now"]) - C.PROVISIONAL_MIN for b in prov)
    # An hour later the last provisional bouts are re-labelled and superseded; finalized history is not.
    old_final = [b for b in bouts(conn) if b[3] == 0 and b[1] < minute_id(sc["now"]) - 2 * C.REPROCESS_MIN]
    s2 = run(p, sc, now=sc["now"] + 3600, tasks=("activity",))
    assert s2["tasks"]["activity"]["minutes"] < s1["tasks"]["activity"]["minutes"]   # only a recent window
    assert conn.execute("SELECT COUNT(*) FROM inferences WHERE superseded_by IS NOT NULL").fetchone()[0] > 0
    now_final = [b for b in bouts(conn) if b[3] == 0 and b[1] < minute_id(sc["now"]) - 2 * C.REPROCESS_MIN]
    assert now_final == old_final
    # Superseded rows point at an existing newer row.
    for sid, by in conn.execute("SELECT id, superseded_by FROM inferences WHERE superseded_by IS NOT NULL"):
        assert by > sid


def test_new_user_writes_nothing(built, tmp_path):
    p, sc = built("new_user", tmp_path)
    s = run(p, sc)
    assert bouts(db.connect(str(p))) == [] or all(b[2]["label"] == "unknown" for b in bouts(db.connect(str(p))))
    assert s["warnings"] == []


def test_golden_typical_week(built, tmp_path):
    """Exact output is pinned. Regenerate deliberately: FENGSHUI_UPDATE_GOLDEN=1."""
    p, sc = built("typical_week", tmp_path)
    run(p, sc)
    conn = db.connect(str(p))
    got = [[s, e, v, prov] for s, e, v, prov in bouts(conn)] + \
          [[s, e, v, prov] for s, e, v, prov in bouts(conn, "activity_day")]
    if os.environ.get("FENGSHUI_UPDATE_GOLDEN") or not GOLDEN.exists():
        GOLDEN.parent.mkdir(parents=True, exist_ok=True)
        GOLDEN.write_text(json.dumps(got, sort_keys=True, separators=(",", ":")))
    assert got == json.loads(GOLDEN.read_text())
