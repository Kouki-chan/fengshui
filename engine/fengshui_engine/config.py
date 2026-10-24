"""Every tunable number the algorithms use (spec §0). No magic numbers elsewhere.

Changes to these values are logged in docs/DECISIONS.md.
"""

# ---------------------------------------------------------------- places (spec §6.2)
PLACE_DEFAULT_RADIUS_M = 150.0
SUGGEST_MIN_VISITS = 3            # unmatched visits needed to suggest a place
SUGGEST_CLUSTER_RADIUS_M = 150.0  # visits within this distance belong together
SUGGEST_MIN_VISIT_MIN = 5         # ignore pass-throughs shorter than this
SUGGEST_LOOKBACK_DAYS = 60
