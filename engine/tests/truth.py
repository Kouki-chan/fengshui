"""Compare activity_bout output with a scenario's per-segment ground truth."""

from __future__ import annotations

import json
from collections import Counter

from fengshui_engine.minute import minute_id


def minute_labels(conn, lo: int, hi: int) -> dict[int, str]:
    out = {}
    for s, e, v in conn.execute("SELECT minute_start, minute_end, value_json FROM inferences WHERE kind='activity_bout' "
                                "AND superseded_by IS NULL AND minute_end > ? AND minute_start < ?", (lo, hi)):
        lab = json.loads(v)["label"]
        for m in range(max(s, lo), min(e, hi)):
            out[m] = lab
    return out


def truth_labels(sc: dict, lo: int, hi: int) -> dict[int, str]:
    out = {}
    for s, e, lab in sc["truth"]:
        for m in range(max(minute_id(s), lo), min(minute_id(e), hi)):
            out[m] = lab
    return out


def agreement(conn, sc: dict, lo: int, hi: int) -> tuple[float, Counter, dict[str, float]]:
    """(overall accuracy, confusion counter (truth, predicted), per-truth-label recall)."""
    pred, true = minute_labels(conn, lo, hi), truth_labels(sc, lo, hi)
    conf = Counter((t, pred.get(m, "none")) for m, t in true.items())
    total = sum(conf.values())
    ok = sum(n for (t, p), n in conf.items() if t == p)
    recall = {}
    for lab in {t for t, _ in conf}:
        n = sum(v for (t, _), v in conf.items() if t == lab)
        recall[lab] = conf[(lab, lab)] / n
    return ok / total if total else 0.0, conf, recall
