"""Every tunable number the algorithms use (spec §0). No magic numbers elsewhere.

Changes to these values are logged in docs/DECISIONS.md.
"""

# ---------------------------------------------------------------- places (spec §6.2)
PLACE_DEFAULT_RADIUS_M = 150.0
SUGGEST_MIN_VISITS = 3            # unmatched visits needed to suggest a place
SUGGEST_CLUSTER_RADIUS_M = 150.0  # visits within this distance belong together
SUGGEST_MIN_VISIT_MIN = 5         # ignore pass-throughs shorter than this
SUGGEST_LOOKBACK_DAYS = 60

# ---------------------------------------------------------------- features (spec §10.1 step 1)
FEATURE_VERSION = "features-v1"
ENMO_LIGHT_MG = 45.0              # "active" 5 s epoch threshold
EPOCH_S = 5
CADENCE_MIN_HZ = 0.5
CADENCE_MAX_HZ = 3.5
CADENCE_WINDOW_S = 10
CADENCE_MIN_CORR = 0.3
CADENCE_RATE_HZ = 25.0            # |a| is decimated to this rate before autocorrelation (speed)
CADENCE_MIN_SD_MG = 13.0          # skip cadence for still minutes (no periodicity to find)
BARO_M_PER_HPA = 8.3
BARO_FIT_WINDOW_MIN = 2           # ± minutes of barometer samples in the vertical-speed fit
FEATURES_MAX_MINUTES_PER_RUN = 4 * 1440   # bound one run's work; the rest goes next run

# ---------------------------------------------------------------- activity (spec §10.1)
ACTIVITY_VERSION = "activity-v1"
ACTIVITY_FIRST_RUN_DAYS = 14      # how far back the first run labels (then incremental)
HR_INTERP_MAX_GAP_MIN = 10
RESTING_HR_DAYS = 7
MAX_HR_INTERCEPT = 208.0
MAX_HR_SLOPE = 0.7
DEFAULT_AGE = 35
DEFAULT_RESTING_HR = 60.0

WATCH_OFF_SD_MG = 13.0
WATCH_OFF_MIN_RUN = 60
RUN_STEPS = 130
RUN_STEPS_PARTIAL = 110           # partial running evidence starts here
RUN_CADENCE_HZ = 2.4
RUN_ENMO_MG = 250.0
WALK_STEPS_MIN = 60
WALK_STEPS_PARTIAL = 40
WALK_CADENCE_HZ = (1.4, 2.4)
WALK_ENMO_MG = (60.0, 250.0)
STAIRS_VERT_SPEED_M_MIN = 3.0
CYCLE_HRR = 0.40
CYCLE_HRR_PARTIAL = 0.30
CYCLE_MAX_STEPS = 20
CYCLE_ENMO_MG = (40.0, 150.0)
VEHICLE_ENMO_MG = 45.0
VEHICLE_MAX_STEPS = 10
SEDENTARY_ENMO_MG = 45.0
SEDENTARY_MAX_STEPS = 10
LIGHT_ENMO_MG = (45.0, 100.0)
LIGHT_MAX_STEPS = 60
PHONE_CONF_MIN = 1                # phone motion counts from medium confidence

# Partial-evidence scores (documented in docs/ALGORITHMS.md).
SCORE_FULL = 1.0
SCORE_PHONE_HIGH = 1.0
SCORE_PHONE_MEDIUM = 0.8
SCORE_PHONE_LOW = 0.4
SCORE_RAW_WALK = 0.8
SCORE_ONE_SOURCE = 0.7
SCORE_TWO_SOURCES = 0.85
SCORE_VEHICLE_INFERRED = 0.7
SCORE_CYCLE_HR = 0.9
SCORE_CYCLE_PARTIAL = 0.4
SCORE_LIGHT_STEPS_ONLY = 0.6
SCORE_LIGHT_HIGH_ENMO = 0.5
SCORE_RUN_PARTIAL = 0.6
SCORE_WALK_FAST = 0.3             # ≥ RUN_STEPS still looks a bit like walking
SCORE_SED_WHEN_OFF = 0.2           # stillness while the watch is off says nothing about the person
SCORE_FLAT_WHEN_CLIMBING = 0.1    # walking/running when climbing evidence exists (stairs is more specific)

SWITCH_PENALTY = 2.0
EMISSION_EPS = 1e-3
MIN_BOUT_MIN = {"walking": 2, "running": 2, "stairs": 2, "cycling": 5, "in_vehicle": 5,
                "sedentary": 3, "light": 3, "watch_off": 3}
INTENSITY_MODERATE_HRR = 0.40
INTENSITY_VIGOROUS_HRR = 0.60
BRISK_WALK_STEPS = 100
REPROCESS_MIN = 120               # each run re-labels from (last finalized − this)
PROVISIONAL_MIN = 120             # bouts ending within this of now are provisional

# ---------------------------------------------------------------- wind-down (spec §10.2)
WIND_DOWN_VERSION = "wind_down-v1"
SLEEP_MERGE_GAP_MIN = 45
MAIN_SLEEP_MIN_H = 3.0
NIGHTS_LOOKBACK = 28
WORKDAY_WEEKS = 4
WORKDAY_MIN_WEEKS = 2
WAKE_HALF_LIFE_DAYS = 7.0
NEED_PRIOR_MIN = 480.0
NEED_PRIOR_WEIGHT = 4
NEED_CLAMP = (420.0, 540.0)
DEBT_NIGHTS = 7
DEBT_CLAMP = (0.0, 300.0)
EXTRA_DIVISOR = 3.0
EXTRA_MAX_MIN = 45.0
LATENCY_NIGHTS = 14
LATENCY_DEFAULT_MIN = 15.0
LATENCY_CLAMP = (5.0, 45.0)
WIND_DOWN_LEN_DEFAULT = 60.0
WIND_DOWN_LEN_RANGE = (30.0, 90.0)
WIND_DOWN_LEN_STEP = 15.0
HABITUAL_NIGHTS = 14
HABITUAL_MAX_EARLIER_MIN = 60.0
MAX_SHIFT_PER_NIGHT_MIN = 30.0
ADJUST_WINDOW_H = 3.0             # evening adjustments start this long before wind_down_start
ADJUST_WORKOUT_MIN = 15.0
ADJUST_HR_MIN = 15.0
ADJUST_HR_ABOVE_RESTING = 15.0
ADJUST_HR_WINDOW_MIN = 30
ADJUST_MAX_TOTAL_MIN = 30.0
HOME_PROMPT_WINDOW_MIN = 90
SUPERSEDE_MIN_SHIFT_MIN = 5.0
COLD_START_NIGHTS = 3
CONFIDENCE = ((3, 0.3), (14, 0.6))    # (< nights, confidence); else CONFIDENCE_HIGH
CONFIDENCE_HIGH = 0.85
CONFIDENCE_WAKE_SD_MIN = 60.0
CONFIDENCE_WAKE_SD_FACTOR = 0.8
OUTCOME_LATENCY_NIGHTS = 7
OUTCOME_LONG_LATENCY_MIN = 30.0
OUTCOME_SHORT_LATENCY_MIN = 10.0
OUTCOME_FOLLOWED_SLACK_MIN = 30.0
DEFAULT_COLD_BEDTIME = "23:00"
DEFAULT_COLD_WAKE = "07:00"
