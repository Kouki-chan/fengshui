# Fengshui — Build Brief for Claude Code

You are building **Fengshui**, a personal proof-of-concept iPhone + Apple Watch app with an embedded Python inference engine and a Python server that runs on this Mac. This document is the complete specification. Read all of it before writing anything.

**How this build runs:** I will be away from the computer most of the time, watching from my phone. You work through **all** phases on your own and **test everything yourself as you go** (section 14). I do one hands-on test on my real iPhone and watch **at the very end** (section 16). Only stop for the few things only I can do (section 0, "Questions for me").

**Order of work:**
1. **Ask me all upfront questions in one message** (section 0), then continue as soon as I answer.
2. **Task A — GitHub setup** (below).
3. **Task B — Export all my Health data to the Desktop** (below). It doesn't block anything: build the importer now, run it whenever my export appears.
4. Write `docs/PLAN.md` and `docs/TEST_STRATEGY.md`, push them, and **continue without waiting** for approval.
5. Build phases 0–8 (section 14). Each phase must pass its **automated test gate** before you move on.
6. Write `docs/DEVICE_TEST_CHECKLIST.md` for my final on-device test, then tell me the build is ready.

---

## Task A — GitHub setup

All work lives in this GitHub repository and must be kept up to date there: **https://github.com/Kouki-chan/fengshui.git**

- Clone it to `~/Developer/fengshui` (ask me if I want a different path). If it's empty, initialize it there with a `main` branch and set this URL as `origin`.
- Check that git can push (`gh auth status` or a test `git ls-remote`). If it can't, include how to authenticate (e.g. `gh auth login`) in your upfront questions, and commit locally until I've done it. Never ask me to paste a token into the chat or into a file.
- Check whether the repo is public or private. **It should be private**, since it will describe my health setup; if it's public, say so in your upfront questions and don't push until I've made it private.
- **Branching:** one branch per phase (`phase-0-foundations`, `phase-1-healthkit`, …). Make small commits with clear messages and **push after every commit**, so GitHub always has the latest work. When a phase passes its automated test gate (section 14), merge it into `main`, tag it `phase-N`, push the tag, and start the next phase. No approval from me needed.
- **Before every push**, check that nothing private is staged: no `*.sqlite`, `*.db`, `*.zip`, `export.xml`, `.env`, `Config/Local.xcconfig`, API keys (search for `sk-ant-`), bearer tokens or my Team ID. Set up `.gitignore` for all of these on the first commit. My real Health data must **never** be committed — only synthetic test data goes in the repo.
- Keep `docs/PROGRESS.md` current and pushed at the end of each working session.

## Task B — Export all my Health data to the Desktop

A Mac can't read the iPhone's Health database directly, so this has a manual part (me) and a code part (you). It gives us my real data to develop and test the algorithms against before the app exists.

**Part 1 — me, on the iPhone.** Include these steps in your upfront questions. **Don't wait for the file**: build and test the importer against the synthetic fixture, check for `~/Desktop/HealthExport/export.zip` at the start of each phase, and run the import as soon as it appears.
1. Health app → tap the profile picture (top right) → **Export All Health Data** → Export. This can take several minutes.
2. AirDrop the resulting `export.zip` to this Mac.
3. Move it to `~/Desktop/HealthExport/export.zip`.

**Part 2 — you.**
- Unzip into `~/Desktop/HealthExport/apple_health_export/` (expect `export.xml`, possibly `export_cda.xml`, `workout-routes/*.gpx`, `electrocardiograms/*.csv`). Never modify or delete the original zip.
- Write `scripts/import_health_export.py` (Python 3.13, standard library only). `export.xml` can be several GB, so parse it **streaming** with `xml.etree.ElementTree.iterparse`, clearing each element after use; never load the whole file into memory.
- Output **`~/Desktop/HealthExport/fengshui_health.sqlite`** using the schema in section 5 (`schema_version`, `processed_samples`, `processed_route_points`, `characteristics`), so the engine can run against it unchanged. Mapping:
  - `<Record>` → one `processed_samples` row: `type` → `hk_type`; `label` by the snake_case rule in 6.1; numeric `value`, or `value_text` for category values (e.g. `HKCategoryValueSleepAnalysisAsleepCore` → `asleep_core`); `unit`; `startDate`/`endDate` (format `2026-10-24 07:15:00 -0400`) → UTC Unix seconds; `minute_id` from start; `sourceName` → `source_name`; `device`; nested `MetadataEntry` and HRV beat lists → `metadata_json`.
  - The export has no HealthKit UUIDs, so set `hk_uuid = "export:" + sha1(hk_type|start|end|source_name|value|value_text)`. This makes re-imports idempotent. Document in `docs/DECISIONS.md` how the app's later HealthKit sync (real UUIDs) will avoid duplicating these rows (match on the same tuple).
  - `<Workout>` → `label = workout`, `value` = duration in seconds, `value_text` = activity type, statistics and events in `metadata_json`; its route GPX file → `processed_route_points`.
  - `<Me>` → `characteristics` (date of birth, biological sex, blood type, skin type).
  - `<ActivitySummary>` → one row per day, `label = activity_summary`, fields in `metadata_json`.
  - ECG CSV files → one `electrocardiogram` row per file with the voltages in `metadata_json` (probably none — my watch has no ECG).
  - Clinical records (`export_cda.xml`): don't import; just count them in the report.
- With a `--csv` flag, also write one CSV per label to `~/Desktop/HealthExport/csv/`.
- Write **`~/Desktop/HealthExport/import_report.md`**: rows per label, date range per label, sources and devices seen, warnings (unparseable records, unknown types), file sizes and run time.
- Re-running with a newer export must add only new rows.
- Tests: a tiny **synthetic** `export.xml` fixture in the repo (`fixtures/health_export_sample.xml`) covering records, categories, a workout with a route, `<Me>`, and an activity summary. Never commit anything derived from my real export.
- In Phase 4, use this database locally to sanity-check the algorithms on my real data (results summarized in `docs/PROGRESS.md` without raw values); keep the committed golden tests synthetic.

---

## 0. How to work

- **Questions for me — ask them all at once, at the start.** Only these need me; put them in one message with clear steps for each, then carry on with whatever doesn't depend on the answers:
  1. GitHub: is git able to push? If not, how to run `gh auth login`.
  2. Xcode: sign in to Xcode → Settings → Accounts with my Apple Account (free Personal Team) so you can read the Team ID.
  3. Permission to install XcodeGen with Homebrew (and anything else system-wide you'll need — list it now).
  4. My Health export (Task B, Part 1) — whenever I get to it.
  5. Optional: whether `ANTHROPIC_API_KEY` is set in my shell environment for live Claude tests (section 14, Phase 7). Never ask me to paste the key into the chat or a file.
- **After that, don't stop for approval.** Only stop if you're truly blocked on something only I can do; otherwise mark the item blocked in `docs/PROGRESS.md`, work around it with the next independent piece, and include it in the final report. My phone gets a push notification whenever you need me.
- **Plan first, briefly.** Write `docs/PLAN.md` (how you'll implement each phase; any part of this spec you believe is wrong or impossible on current SDKs, with your chosen alternative) and `docs/TEST_STRATEGY.md` (section 14). Push them and continue.
- **Work in phases** (section 14). At the end of each phase: run the phase's full automated test gate plus all earlier gates (no regressions), commit and push (Task A rules), update `docs/PROGRESS.md` with what was built, what was tested and how, and the results. Then merge and move on.
- **Test as you build, not after.** Write tests alongside the code. A phase isn't done until its gate passes. If a test can't pass after a genuine effort, don't delete or weaken it: mark it `expected failure` with the reason, list it in `docs/PROGRESS.md`, and continue.
- **Verify, don't assume.** Apple APIs change yearly. Before relying on an API, check its current availability for **iOS 26 / watchOS 10** in the SDK headers or docs that ship with Xcode 27. If something in this spec doesn't exist or behaves differently, choose the closest sound alternative, record it in `docs/DECISIONS.md`, and keep going; only stop if the choice would change what the app does for me in a big way.
- **No private APIs, no workarounds that break Apple's rules** (e.g. don't keep an HKWorkoutSession running all day to get background sensor access). If a platform limit blocks a feature, report it.
- **Ask before** installing anything system-wide (Homebrew packages, global pip installs), changing signing settings, or deleting files outside the repo. Batch these into the upfront questions wherever possible.
- **Secrets:** never commit API keys, tokens or my Team ID. Use `.gitignore`, a local `Config/Local.xcconfig` (gitignored) and environment variables.
- **Every tunable number** in the algorithms (thresholds, windows, penalties) lives in one config file (`engine/fengshui_engine/config.py`), never as magic numbers in code.
- Keep the code readable for a solo developer: small files, clear names, comments explaining *why*.

---

## 1. Environment (fixed)

| Item | Value |
| --- | --- |
| Mac | Mac mini, Apple M6, 16 GB RAM, 256 GB disk (keep disk use modest) |
| macOS | 27.0 |
| Xcode | 27.0 (Swift 6.4). Supports on-device debugging for iOS 17+ and **watchOS 10+** |
| iPhone | iPhone 17 Pro, iOS 26.0.1 |
| Watch | Apple Watch SE (1st gen, 2020), 44mm GPS, model MYDT2LL/A, **watchOS 10.6.2 — cannot update past watchOS 10** |
| Developer account | **Free Apple Developer account (Personal Team) for now**; paid Apple Developer Program later. See section 1a. Put the Team ID only in the gitignored xcconfig |
| App name | Fengshui |
| Bundle IDs | iPhone `com.chevin.fengshui`; Watch `com.chevin.fengshui.watchkitapp`; extensions `com.chevin.fengshui.<name>` |
| App Group | `group.com.chevin.fengshui` |
| Deployment targets | iOS 26.0; watchOS 10.0 |
| Usage | Personal use only, one user, no App Store submission |

Watch SE (1st gen) hardware: optical heart rate, accelerometer, gyroscope, barometric altimeter, compass. **No** ECG, blood oxygen or wrist temperature — those HealthKit types will be empty; handle that gracefully.

### 1a. Free developer account (for now)

I'm starting with a **free Apple Developer account (Xcode "Personal Team")** and will upgrade to the paid program later. Build so the upgrade is a configuration change, not a rewrite.

- **Signing:** automatic signing with my Personal Team. Ask me to sign in to Xcode → Settings → Accounts with my Apple Account; read the Personal Team ID from Xcode and put it only in `Config/Local.xcconfig`.
- **Capabilities available on a Personal Team** (per Apple's supported-capabilities tables): HealthKit, App Groups, Background Modes, Data Protection, on both iPhone and Watch. Whether HealthKit **background delivery** works on a Personal Team can only be confirmed on my real phone, so build the fallback in from the start (sync on app launch and background refresh too) and put the check in the final device test.
- **Not available on a Personal Team: Family Controls.** So **Screen Time is deferred**: don't create the `ScreenTimeMonitor` extension target yet, keep the `context_screen_events` table and all code paths that read it (they just return nothing), and put the extension and onboarding step behind a build flag `FENGSHUI_PAID_ACCOUNT` (off by default). Skip Spike B.
- **7-day expiry:** apps signed with a free account stop launching after about 7 days and must be reinstalled from Xcode. Reinstalling over the existing app keeps its data. Add to Settings a "Signing expires in N days" line (read the expiration date from the embedded provisioning profile when present) and a notification 1 day before expiry reminding me to reinstall.
- **Limits:** free accounts allow only a few apps installed per device and a limited number of new App IDs per week. Keep exactly two App IDs (`com.chevin.fengshui` and `com.chevin.fengshui.watchkitapp`), never create throwaway bundle IDs for experiments (spike inside the main targets instead), and tell me if Xcode reports a limit.
- No push notifications are needed (all notifications are local), and MapKit pin-dropping works without the paid program.

**Switching to the paid account later** (write these steps into `docs/PAID_ACCOUNT_SWITCH.md`):
1. Back up first: run a full server sync and raw archive, and export the phone database to the Mac.
2. Change the team in `Config/Local.xcconfig`, regenerate the project.
3. A different signing team may not be able to install over the existing app, or register the same bundle IDs. If so, delete the app from the phone and watch, reinstall, then restore from the Mac backup (HealthKit data itself is safe in Apple Health and can be re-backfilled).
4. Turn on `FENGSHUI_PAID_ACCOUNT`, add the Family Controls capability and the `ScreenTimeMonitor` extension, then run Spike B and the Screen Time part of Phase 2.

---

## 2. What the product does

1. **iPhone app** reads all HealthKit data (one-time backfill, then incremental), plus location (significant places only), iPhone motion activity and Screen Time threshold events. Everything goes into a SQLite database on the phone.
2. **Watch app** records sensor data passively in battery-efficient tiers and sends compressed one-minute chunks to the phone, stored in a separate "raw" table linked by the same `minute_id`.
3. The user chooses at first launch what is recorded; the choice is remembered and editable.
4. A **Python inference engine** turns data into inferences (this phase: **activity detection** and **wind-down timing**; caffeine is explicitly out of scope). Inferences go to their own table.
5. The engine runs **on the phone by default** (embedded Python), and the identical engine can run **on the Mac server** instead (setting: phone / server / auto).
6. The phone schedules **local notifications** (e.g. "start winding down") that must fire within **5 minutes** of the intended time.
7. **Claude** (Anthropic API) answers preset questions (set by me or the user) and free-form user questions. Claude receives only processed iPhone data and inferences via tools — **never raw watch data**.
8. A **Python server on this Mac** receives synced data, archives raw chunks older than 7 days, and can run the engine remotely.

---

## 3. Repository layout

Inside the cloned repo `~/Developer/fengshui` (Task A):

```
fengshui/
  docs/            PLAN.md, PROGRESS.md, SPEC.md (copy of this file), DECISIONS.md
  apple/
    project.yml    XcodeGen spec (generate the .xcodeproj; don't hand-edit it)
    Config/        Shared.xcconfig, Local.xcconfig (gitignored: DEVELOPMENT_TEAM etc.)
    FengshuiKit/   Swift package shared by iPhone + Watch (models, minute_id, raw encoding, prefs)
    Fengshui/      iPhone app target
    FengshuiWatch/ Watch app target
    ScreenTimeMonitor/  DeviceActivityMonitor extension target (added later, paid account only — see 1a)
    Python/        embedded Python runtime + bundled engine (build-phase output; see 8)
    Tests/         Swift unit tests
  engine/
    pyproject.toml
    fengshui_engine/  pure-Python package (see 8–10)
    tests/            pytest, synthetic data fixtures
  server/
    pyproject.toml
    fengshui_server/  FastAPI app (see 12)
    tests/
  fixtures/        synthetic test data only: raw-encoding vectors, golden outputs, sample export.xml
  scripts/         bootstrap.sh, build_python_ios.sh, run_server.sh, import_health_export.py
```

Use **XcodeGen** (`brew install xcodegen` — ask first) so the project is reproducible from `project.yml`. Use **GRDB.swift** (Swift Package Manager) for SQLite on the phone. Python 3.13 for engine and server (use a project venv; no global installs).

---

## 4. Shared conventions

- **`minute_id = floor(unix_seconds_utc / 60)`** — an integer. Every row in every table that refers to time carries a `minute_id` (or `minute_start`/`minute_end`). It's computed identically on watch, phone and server; no lookup table.
- All timestamps stored as **Unix seconds UTC (REAL)**. Local-time logic (bedtimes, "workday") uses the device's current IANA time zone, stored in `preferences` and passed to the engine. Bundle the `tzdata` Python package so `zoneinfo` works inside the iOS app.
- SQLite in **WAL mode**, `busy_timeout = 5000`, foreign keys on. Swift writes collection tables; the Python engine writes only `raw_minute_features`, `inferences`, `engine_state` and `context_places` rows of kind `suggested`.
- Rows are append-only except: marking HealthKit deletions (`deleted = 1`), superseding inferences, archiving raw payloads.
- Schema migrations: a `schema_version` table and numbered migrations in both Swift (GRDB migrator) and Python (engine checks version and refuses to run on an unknown schema).

---

## 5. Database schema (v1)

Implement exactly this (add indexes as needed, document any change in `docs/DECISIONS.md`):

```sql
CREATE TABLE schema_version (version INTEGER NOT NULL);

-- PROCESSED: everything from HealthKit
CREATE TABLE processed_samples (
  id INTEGER PRIMARY KEY,
  hk_uuid TEXT UNIQUE NOT NULL,
  hk_type TEXT NOT NULL,            -- full HealthKit identifier
  label TEXT NOT NULL,              -- snake_case short label, e.g. heart_rate
  value REAL,                       -- numeric value, or category raw value
  value_text TEXT,                  -- category label, e.g. asleep_deep
  unit TEXT,
  start_ts REAL NOT NULL,
  end_ts REAL NOT NULL,
  minute_id INTEGER NOT NULL,       -- from start_ts
  source_name TEXT, source_bundle TEXT, device TEXT,
  metadata_json TEXT,
  deleted INTEGER NOT NULL DEFAULT 0,
  inserted_at REAL NOT NULL
);
CREATE INDEX ix_ps_label_time ON processed_samples(label, start_ts);
CREATE INDEX ix_ps_minute ON processed_samples(minute_id);

CREATE TABLE processed_route_points (     -- workout routes
  id INTEGER PRIMARY KEY,
  workout_uuid TEXT NOT NULL,
  ts REAL NOT NULL, minute_id INTEGER NOT NULL,
  lat REAL, lon REAL, alt_m REAL, speed_mps REAL, h_accuracy REAL
);

CREATE TABLE characteristics (key TEXT PRIMARY KEY, value TEXT);  -- date_of_birth, biological_sex...

-- RAW: watch sensor chunks, one per sensor per minute
CREATE TABLE raw_chunks (
  id INTEGER PRIMARY KEY,
  minute_id INTEGER NOT NULL,
  sensor TEXT NOT NULL,             -- accel | gyro | baro | compass | hr_session
  tier INTEGER NOT NULL,            -- 1 passive, 2 snapshot, 3 session
  rate_hz REAL NOT NULL,
  sample_count INTEGER NOT NULL,
  axes INTEGER NOT NULL,
  encoding TEXT NOT NULL,           -- 'fsr1-i16-delta-deflate'
  scale REAL NOT NULL,              -- physical = int * scale + offset
  offset REAL NOT NULL DEFAULT 0,
  payload BLOB,                     -- NULL after archive
  archive_ref TEXT, archived_at REAL,
  received_at REAL NOT NULL,
  UNIQUE(minute_id, sensor, tier)
);

CREATE TABLE raw_minute_features (
  minute_id INTEGER PRIMARY KEY,
  accel_samples INTEGER,
  enmo_mg REAL,                     -- mean(max(|a| - 1g, 0)) in milli-g
  mag_sd_mg REAL,                   -- std dev of |a| in milli-g
  cadence_hz REAL,                  -- dominant periodicity 0.5–3.5 Hz, NULL if none
  active_frac REAL,                 -- share of 5 s epochs with enmo > light threshold
  pressure_kpa REAL,
  vert_speed_m_min REAL,
  heading_change_deg REAL,
  gyro_rms_dps REAL,
  feature_version TEXT NOT NULL,
  computed_at REAL NOT NULL
);

-- CONTEXT
CREATE TABLE context_motion (       -- iPhone CMMotionActivity segments
  id INTEGER PRIMARY KEY,
  start_ts REAL NOT NULL, end_ts REAL,
  minute_id INTEGER NOT NULL,
  activity TEXT NOT NULL,           -- stationary|walking|running|automotive|cycling|unknown
  confidence INTEGER NOT NULL,      -- 0 low, 1 medium, 2 high
  UNIQUE(start_ts, activity)
);

CREATE TABLE context_places (
  id INTEGER PRIMARY KEY,
  name TEXT NOT NULL,
  kind TEXT NOT NULL,               -- home | work | custom | suggested
  lat REAL NOT NULL, lon REAL NOT NULL,
  radius_m REAL NOT NULL DEFAULT 150,
  confirmed INTEGER NOT NULL DEFAULT 1,
  created_at REAL NOT NULL
);

CREATE TABLE context_visits (
  id INTEGER PRIMARY KEY,
  place_id INTEGER REFERENCES context_places(id),
  lat REAL NOT NULL, lon REAL NOT NULL, h_accuracy REAL,
  arrival_ts REAL NOT NULL, departure_ts REAL,   -- departure NULL while ongoing
  minute_start INTEGER NOT NULL, minute_end INTEGER
);

CREATE TABLE context_screen_events (
  id INTEGER PRIMARY KEY,
  ts REAL NOT NULL, minute_id INTEGER NOT NULL,
  schedule TEXT NOT NULL,           -- daily | evening
  threshold_min INTEGER NOT NULL,
  UNIQUE(ts, schedule, threshold_min)
);

-- INFERENCES
CREATE TABLE inferences (
  id INTEGER PRIMARY KEY,
  kind TEXT NOT NULL,               -- activity_bout | activity_day | wind_down_plan | wind_down_outcome
  minute_start INTEGER NOT NULL, minute_end INTEGER NOT NULL,
  value_json TEXT NOT NULL,
  confidence REAL,
  algorithm TEXT NOT NULL, algorithm_version TEXT NOT NULL,
  computed_at REAL NOT NULL,
  computed_where TEXT NOT NULL,     -- phone | server
  provisional INTEGER NOT NULL DEFAULT 0,
  superseded_by INTEGER REFERENCES inferences(id)
);
CREATE INDEX ix_inf_kind_time ON inferences(kind, minute_start);

CREATE TABLE engine_state (key TEXT PRIMARY KEY, value TEXT);   -- watermarks per task

-- SYSTEM
CREATE TABLE notifications_log (
  id INTEGER PRIMARY KEY,
  inference_id INTEGER REFERENCES inferences(id),
  kind TEXT NOT NULL, identifier TEXT NOT NULL,
  scheduled_for REAL, delivered_at REAL, cancelled_at REAL, created_at REAL NOT NULL
);
CREATE TABLE preferences (key TEXT PRIMARY KEY, value_json TEXT NOT NULL, updated_at REAL NOT NULL);
CREATE TABLE sync_state (           -- HealthKit anchors
  hk_type TEXT PRIMARY KEY, anchor BLOB, last_sync_ts REAL, backfill_done INTEGER NOT NULL DEFAULT 0
);
CREATE TABLE server_sync_state (table_name TEXT PRIMARY KEY, last_id_uploaded INTEGER, last_ts REAL);
CREATE TABLE ai_questions (
  id INTEGER PRIMARY KEY,
  owner TEXT NOT NULL,              -- dev | user
  text TEXT NOT NULL,
  schedule TEXT,                    -- NULL = on demand; e.g. 'weekly:sun:19:00'
  enabled INTEGER NOT NULL DEFAULT 1,
  created_at REAL NOT NULL
);
CREATE TABLE ai_log (
  id INTEGER PRIMARY KEY,
  ts REAL NOT NULL, question TEXT NOT NULL, model TEXT NOT NULL,
  tool_calls_json TEXT, response_text TEXT,
  input_tokens INTEGER, output_tokens INTEGER, error TEXT
);
```

---

## 6. iPhone data collection

### 6.1 HealthKit
- Request **read** access to every HealthKit object type available on iOS 26: all `HKQuantityTypeIdentifier`s, all `HKCategoryTypeIdentifier`s, workouts, heartbeat series, workout routes, ECG, audiograms, state of mind, and characteristics. **Exclude clinical records** (needs a special entitlement). Build the list programmatically where possible and log which types exist.
- Request **share** (write) only for workouts (needed for Watch tier-3 sessions).
- Label mapping: strip the `HK…TypeIdentifier` prefix and convert to snake_case (`HKQuantityTypeIdentifierHeartRate` → `heart_rate`). Units from `preferredUnits(for:)`, falling back to a sensible default per type. Category values also get a readable `value_text` (sleep: `in_bed`, `asleep_unspecified`, `asleep_core`, `asleep_deep`, `asleep_rem`, `awake`).
- **Backfill**: one `HKAnchoredObjectQuery` per type over all history; write in batches of 5,000 rows per transaction; show a progress screen; resumable (anchors saved after each batch).
- **Incremental**: same anchored queries from the saved anchor; handle `deletedObjects` by setting `deleted = 1`.
- **Background delivery** (entitlement `com.apple.developer.healthkit.background-delivery`): register `HKObserverQuery` + `enableBackgroundDelivery(.immediate)` for sleep analysis, heart rate, step count, workouts, HRV, resting heart rate. Accept that the system clamps frequency for some types. On each callback: sync that type, then trigger an engine run (section 9).
- Workouts: store as `label = workout`, value = duration (s), `value_text` = activity type name, metadata_json with energy/distance. Routes → `processed_route_points`. Heartbeat series → one row with value = beat count and the beat timestamps in `metadata_json`.

### 6.2 Location (significant places only)
- "Always" authorization. Use **visit monitoring** and **significant-location-change** only — no continuous GPS.
- Onboarding asks the user to set **Home**, **Work**, and optionally other named places (MapKit pin drop or "use current location"). Each named place gets a geofence (default radius 150 m) using the current geofencing API (`CLMonitor` if available on iOS 26).
- Visits → `context_visits`, matched to the nearest place within its radius (else `place_id` NULL).
- The engine (task `place_suggestions`) clusters unmatched visits (≥ 3 visits within 150 m) into `context_places` rows with `kind = 'suggested'`, `confirmed = 0`. The app shows them for naming or dismissal.
- Region entry for Home must wake the app (used by wind-down, section 10.2 step 7).

### 6.3 iPhone motion
- On each sync, query `CMMotionActivityManager` history since the last stored segment (iOS keeps ~7 days) → `context_motion`.

### 6.4 Screen Time (threshold events only) — deferred until the paid account (see 1a)
- Build this only when `FENGSHUI_PAID_ACCOUNT` is on. Until then, the table exists and stays empty.
- Apple does not let apps export Screen Time usage. We only log **threshold crossings**.
- Use FamilyControls (`.individual` authorization) + DeviceActivity. In onboarding, the user selects **all app categories** once in `FamilyActivityPicker` (needed to define "total use").
- Schedules: `daily` 00:00–23:59 with events at 30, 60, 90 … 480 min; `evening` 21:00–23:59 with events at 15, 30, 60 min.
- The `ScreenTimeMonitor` extension's `eventDidReachThreshold` records `{ts, schedule, threshold}` to the App Group container; the app imports into `context_screen_events`.
- **This is a known risk:** reports exist that DeviceActivity extensions cannot write to shared containers. **Spike this first** when the paid account is enabled (Spike B in `docs/PAID_ACCOUNT_SWITCH.md`). If writing is blocked, mark Screen Time as unavailable in the UI and continue without it.

---

## 7. Watch app

### 7.1 Recording tiers (battery-efficient)

| Tier | Records | Mechanism | Default |
| --- | --- | --- | --- |
| 0 | Apple's own HR, HRV, steps, sleep, workouts | Already in HealthKit, read on the phone. Nothing to do on the watch | Always |
| 1 | Accelerometer 50 Hz, continuous | `CMSensorRecorder.recordAccelerometer(forDuration: 12 h)`, re-armed on every wake. watchOS keeps data ~3 days | On |
| 2 | Short snapshot of gyroscope, barometer (pressure), compass heading | On each `WKApplicationRefreshBackgroundTask`; length default **5 s** at 25 Hz (configurable 3–10 s), must finish within the background-task budget | On, interval 60 min |
| 3 | All sensors at full rate + HR every ~5 s | User starts/stops a session on the watch; `HKWorkoutSession` (activity `.other`) + `CMMotionManager` device motion 50 Hz + `CMAltimeter` | Off until started |

- Schedule background refresh at the user's chosen interval (30/60/120 min). Document that adding the app's complication to the active watch face increases refresh budget; provide a simple complication.
- **Battery guard:** skip tier 2 when battery < 30% or Low Power Mode is on.
- Log gaps in `CMSensorRecorder` data (e.g. during watch-detected sleep) so they can be measured in the final device test. Don't work around them.

### 7.2 Preferences
- First launch on the **phone** shows one screen: per-sensor toggles (accelerometer, gyroscope, barometer, compass, session heart rate), tier-2 interval, whether sessions are allowed. Stored in `preferences`, mirrored to the watch with `WCSession.updateApplicationContext`, editable in Settings. The watch also has a minimal settings view (read-only mirror + session start/stop).

### 7.3 Raw encoding — `fsr1-i16-delta-deflate`
One chunk = one sensor, one minute. Implement in `FengshuiKit` (Swift) and `fengshui_engine.raw` (Python), with shared test vectors in `fixtures/`.

Byte layout before compression (little-endian):
```
magic        4 bytes  'FSR1'
version      u8       1
sensor_code  u8       1 accel, 2 gyro, 3 baro, 4 compass, 5 hr_session
axes         u8       (accel 3, gyro 3, baro 1, compass 1, hr 1)
reserved     u8       0
start_ts     f64      unix seconds of first sample
rate_hz      f32
n_samples    u32
n_gaps       u16
gaps         n_gaps × (sample_index u32, missing_count u32)
first        axes × i16   first sample, absolute
deltas       (n_samples-1) × axes × i16, interleaved, WRAPPING arithmetic mod 2^16
```
- Quantization (physical = int × scale + offset):
  - accel: scale 1/2048 g, offset 0 (±16 g)
  - gyro: scale 0.001 rad/s, offset 0
  - baro: scale 0.001 kPa, offset 100 kPa
  - compass: heading degrees, scale 0.02°, offset 0
  - hr_session: scale 0.1 bpm, offset 0
- Deltas use **wrapping** int16 arithmetic so decoding is lossless after quantization.
- Compression: Apple's `Compression` framework with `COMPRESSION_ZLIB` produces **raw DEFLATE without a zlib header**. Python must decode with `zlib.decompress(data, -15)`. Add a test that proves Swift-encoded fixtures decode in Python exactly.
- Measure the compression ratio on synthetic traces in Phase 3, and on real data in the final device test.

### 7.4 Transfer to phone
- On each wake, the watch drains new tier-1 accelerometer data (using a stored "last harvested" timestamp), encodes per-minute chunks, and writes one file per hour of data (a small container of chunks with a JSON index).
- Send with `WCSession.transferFile` (metadata: sensor, tier, minute range, encoding). Tier-3 sessions transfer when they end.
- The phone imports into `raw_chunks` (upsert on `(minute_id, sensor, tier)`) and acknowledges via `transferUserInfo`; the watch deletes a file only after its acknowledgment.

---

## 8. Embedded Python engine — architecture

- `engine/fengshui_engine` is a **pure Python package** (standard library + `tzdata`). NumPy is optional: only if Phase 0 shows it builds and loads on iOS, and then only behind a backend switch with tests proving identical results to the pure-Python path.
- **Same package runs on phone and server.** Public entry point:
  ```python
  def run(db_path: str, *, now_ts: float, tz: str, where: str,
          tasks: list[str] | None = None) -> dict:
      """Run the requested tasks (default: all due tasks) against the SQLite DB.
      Idempotent; uses engine_state watermarks. Returns a summary dict
      (tasks run, rows written, timings, warnings)."""
  ```
  Tasks: `features` (raw → raw_minute_features), `activity` (section 10.1), `wind_down` (10.2), `wind_down_outcome` (10.2 step 8), `place_suggestions` (6.2).
- **Embedding on iOS:** Python 3.13+ officially supports iOS. In Phase 0, spike embedding using the BeeWare **Python-Apple-support** XCFramework (or Briefcase-generated support package — your call, document it in DECISIONS.md). Bundle the stdlib + `fengshui_engine` + `tzdata` into the app via a script build phase (`scripts/build_python_ios.sh`). Call `run()` from Swift through a thin C-API wrapper (or PythonKit if it works with the embedded runtime). The engine runs off the main thread inside background tasks, one run at a time (a Swift actor serializes runs).
- Watch has **no Python**; it only records and encodes.
- **Where it runs** (Settings: Phone / Server / Auto). Auto = phone, unless the phone is on Low Power Mode or a backlog > 24 h of unprocessed raw minutes exists and the server is reachable. Server mode: phone syncs (section 12), calls `POST /compute`, receives inference rows and inserts them with `computed_where = 'server'`.
- If embedding stalls in Phase 0, tell me. The fallback is server-only compute first, phone later — algorithms unchanged.

---

## 9. When the engine runs
- After any HealthKit background-delivery sync, visit/region event, watch file import, app foreground.
- `BGAppRefreshTask` (frequent, light: `activity`, `wind_down`).
- `BGProcessingTask` nightly while charging (heavy: `features` backlog, archive upload, `place_suggestions`).
- Every run is idempotent and incremental via watermarks in `engine_state`.

---

## 10. Algorithms

All constants below go in `config.py`. Each algorithm has a version string stored with its inferences (`activity-v1`, `wind_down-v1`). Write thorough pytest suites using a **synthetic data generator** (`engine/tests/synth.py`) that can produce realistic days: sleep with stages, walks, a run, a commute, desk time, watch-off periods, missing data.

### 10.1 Activity detection (`activity-v1`)

**Goal:** label every minute with one activity, smooth into bouts, store each bout and a daily summary.

**Labels:** `workout` (with type), `sleep`, `watch_off`, `sedentary`, `light`, `walking`, `running`, `stairs`, `cycling`, `in_vehicle`, `unknown`.

**Step 1 — per-minute features.** The `features` task computes `raw_minute_features` from raw chunks:
- `enmo_mg` = mean over samples of max(|a| − 1 g, 0), in milli-g.
- `mag_sd_mg` = standard deviation of |a|, milli-g.
- `cadence_hz` = dominant periodicity of |a| between 0.5 and 3.5 Hz (autocorrelation over 10 s windows; median across windows; NULL if the peak correlation < 0.3).
- `active_frac` = share of 5 s epochs with mean enmo > 45 mg.
- `pressure_kpa`, `vert_speed_m_min` from barometer (≈ 8.3 m per hPa; linear fit over available samples ± 2 minutes), `heading_change_deg` from compass, `gyro_rms_dps` from gyro — when snapshots exist.

The `activity` task then assembles, per minute:
| Feature | Source |
| --- | --- |
| steps/min | HealthKit `step_count`, each sample prorated across the minutes it spans |
| HR, % heart-rate reserve | HealthKit `heart_rate` + `hr_session`; interpolate gaps ≤ 10 min; HRR = (HR − resting) / (max − resting); resting = 7-day median of `resting_heart_rate`; max = 208 − 0.7 × age (age from characteristics; default 35 if unknown) |
| raw features | `raw_minute_features` |
| flights climbed | HealthKit `flights_climbed` prorated |
| phone motion | `context_motion` label + confidence |
| place | `context_visits`: at named place / at unnamed place / between places |
| overrides | inside a HealthKit workout; inside main sleep episode (10.2 step 1) |

**Step 2 — label scores (0–1)** per minute; missing sources contribute nothing:
| Label | Evidence (score 1.0 when fully met; scale down partial evidence; document your scoring) |
| --- | --- |
| workout | minute inside a logged workout — hard override |
| sleep | minute inside the main sleep episode — hard override (below workout) |
| watch_off | `mag_sd_mg` < 13 for ≥ 60 consecutive minutes AND no HR samples in that span |
| running | ≥ 130 steps/min, OR phone motion running (conf ≥ 1), OR cadence ≥ 2.4 Hz with enmo > 250 mg |
| walking | 60–129 steps/min, OR phone motion walking (conf ≥ 1) |
| stairs | walking/running evidence AND (flights climbed in minute OR \|vert_speed\| ≥ 3 m/min) |
| cycling | phone motion cycling, OR (HRR ≥ 40% AND < 20 steps/min AND enmo 40–150 mg) |
| in_vehicle | phone motion automotive, OR (between places AND enmo < 45 mg AND < 10 steps/min) |
| sedentary | enmo < 45 mg AND < 10 steps/min AND not in_vehicle evidence |
| light | enmo 45–100 mg AND < 60 steps/min |
| unknown | no usable source for the minute |

**Step 3 — smoothing.** Viterbi over the day: emission cost = −log(score + 1e-3); transition cost = `SWITCH_PENALTY` (start 2.0) for any label change, 0 otherwise; overrides are fixed. Then enforce minimum bout lengths by merging short bouts into the neighbouring bout with the higher mean score:
| Label | Minimum |
| --- | --- |
| walking, running, stairs | 2 min |
| cycling, in_vehicle | 5 min |
| sedentary, light, watch_off | 3 min |

**Step 4 — intensity** per bout from mean HRR: light < 40%, moderate 40–59%, vigorous ≥ 60%. Walking at ≥ 100 steps/min is at least moderate.

**Step 5 — context.** Tag each bout with place (`at Home`, `near Work`, `at unnamed place`, `between places`). `in_vehicle` bouts get `from`/`to` = the places before and after.

**Step 6 — incremental.** Each run reprocesses from (last finalized minute − 120 min). Bouts ending within the last 120 min are `provisional = 1` and are superseded on the next run.

**Confidence** per bout = mean over minutes of (winning score − runner-up score), × share of minutes with ≥ 2 sources.

**Outputs:**
- `activity_bout` rows:
  ```json
  {"label":"walking","intensity":"moderate","start":"2026-10-24T12:14:00-04:00","end":"2026-10-24T12:28:00-04:00",
   "minutes":14,"steps":1512,"avg_hr":104,"place":"near Work","from":null,"to":null,
   "workout_type":null,"sources":["steps","accelerometer","phone_motion"]}
  ```
- `activity_day` (one per local calendar day): minutes per label, moderate+vigorous minutes, longest sedentary bout (min), total steps, watch-off minutes, data coverage %.

**Calibration hook:** write `engine/tools/calibrate.py` (server-side, not shipped) that compares detected labels with logged HealthKit workouts and reports precision/recall per label so I can tune thresholds.

### 10.2 Wind-down (`wind_down-v1`)

**Goal:** each evening, decide when to start winding down: predicted wake time − sleep need − time to fall asleep − wind-down length, adjusted for today and learned from past nights.

**Cold start:** onboarding asks usual workday wake time, free-day wake time, usual bedtime. Used until ≥ 3 nights of data exist.

**Step 1 — nights.** From `sleep_analysis` samples with `value_text` in asleep_* states: merge gaps ≤ 45 min into episodes. The **main sleep** of a night = the longest episode ≥ 3 h; it belongs to the local date of its wake time. Shorter episodes = naps (ignored here). Per night: onset, wake, minutes asleep, sleep latency = onset − start of the overlapping `in_bed` sample (when present).

**Step 2 — day type for tomorrow.** *Workday* if there was a visit to a `work` place on that weekday in ≥ 2 of the last 4 weeks; else *free day*. Weekends default to free days unless the location rule says otherwise. If no Work place is set: Mon–Fri workday.

**Step 3 — predicted wake.** Weighted median of wake times (as minutes after local midnight, circular-safe) for the same day type over the last 28 nights; weight = 0.5^(age_days / 7). A user one-off override ("tomorrow I wake at …", stored in `preferences`) replaces it.

**Step 4 — need and debt.**
- `need = (n_free × median_free + 4 × 480) / (n_free + 4)` minutes, clamped to [420, 540], where median_free = median minutes asleep on free nights in the last 28.
- `debt = Σ (need − actual)` over the last 7 nights (missing nights skipped), clamped to [0, 300].
- `extra = min(debt / 3, 45)`.

**Step 5 — targets.**
- `target_onset = wake − (need + extra)`
- `latency` = median of last 14 measured latencies, default 15, clamped [5, 45]
- `target_in_bed = target_onset − latency`
- `wind_down_len` = current length (starts at 60, adapted in step 8, range [30, 90])
- `wind_down_start = target_in_bed − wind_down_len − adjustments`

**Step 6 — realism guards.**
- `habitual_onset` = weighted median onset of last 14 nights (same weighting).
- `target_onset ≥ habitual_onset − 60 min` (can't fall asleep much earlier than usual).
- `|target_onset − yesterday's target_onset| ≤ 30 min` (gradual shifts).

**Step 7 — evening adjustments** (task re-runs from 3 h before wind-down start; total adjustment ≤ 30 min earlier):
| Signal | Change |
| --- | --- |
| A `moderate`/`vigorous` activity bout or workout ending within 3 h of `target_in_bed` | 15 min earlier |
| Median HR over the last 30 min of non-activity time > 7-day resting HR + 15 bpm | 15 min earlier |
| Not at Home at `wind_down_start` | No time change; the phone also sends a second prompt on Home-region entry if within 90 min after `wind_down_start` |
| An `evening` Screen Time threshold crossed | No time change; add a `reasons` entry |

**Step 8 — learning (`wind_down_outcome`, each morning).** Compare actual in-bed and onset with last night's plan; store `{night_of, planned_*, actual_*, latency, followed: bool}`. If mean latency over the last 7 nights > 30 min → `wind_down_len += 15` (max 90); if < 10 min → `−= 15` (min 30). Persist in `engine_state`.

**Confidence:** 0.3 if < 3 nights; 0.6 for 3–13; 0.85 for ≥ 14; multiply by 0.8 if the std dev of wake times > 60 min.

**Output** — one `wind_down_plan` per night; a re-run that moves `wind_down_start` by more than 5 min supersedes the previous row:
```json
{"night_of":"2026-10-24","day_type_tomorrow":"free","predicted_wake":"08:05",
 "sleep_need_min":472,"sleep_debt_min":95,"extra_tonight_min":32,
 "target_sleep_onset":"23:41","target_in_bed":"23:27","wind_down_start":"22:12",
 "wind_down_len_min":60,"adjustments":[{"reason":"evening_workout","minutes":-15}],
 "habitual_onset":"00:10","nights_used":21,"reasons":[]}
```
(Check: 08:05 − (472 + 32) min = 23:41; − 14 min latency = 23:27; − 60 − 15 = 22:12. Put this exact case in a unit test.)

---

## 11. Notifications (phone only, ≤ 5 min delay)
- **Planned prompts** (wind-down): when a `wind_down_plan` is written or superseded, the Swift side schedules/reschedules a local notification with a calendar trigger at `wind_down_start` (identifier `wind_down_<night_of>`). This is what guarantees the 5-minute target.
- **Place-triggered prompts:** Home-region entry → immediate local notification if the conditions in 10.2 step 7 hold and the user hasn't dismissed tonight's prompt.
- **Data-triggered prompts** (future): best effort only; document this.
- Log every schedule, delivery (`willPresent` / delivered list check), and cancellation in `notifications_log` so actual delay can be measured. Show this in a debug screen.

---

## 12. Mac server (`server/`)
- Python 3.13, **FastAPI + uvicorn**, its own SQLite DB using the **same schema** (plus a `devices` table). Runs on the LAN; `scripts/run_server.sh` starts it; offer an optional `launchd` plist to auto-start at login.
- Auth: a shared bearer token (generated once, stored in the phone's Keychain and in a gitignored `.env` on the server). App Transport Security: allow local networking only (`NSAllowsLocalNetworking`); add `NSLocalNetworkUsageDescription`. Discovery: Bonjour (`_fengshui._tcp`) with a manual URL fallback in Settings.
- Endpoints:
  - `GET /health`
  - `POST /sync` — batched upserts by table (processed, context, preferences, inferences); idempotent by natural keys. Phone tracks progress in `server_sync_state`. Sync over Wi-Fi only.
  - `POST /raw/archive` — raw chunks older than **7 days**; the server stores the blobs unchanged (partition by day) and returns `archive_ref`s. Only after confirmation does the phone set `payload = NULL`.
  - `GET /raw?sensor=&from_minute=&to_minute=` — returns original blobs byte-for-byte.
  - `POST /compute` — run `fengshui_engine.run(..., where="server")` on the server DB and return new/superseded inference rows since a given id.
- Installs `fengshui_engine` from `../engine` in editable mode so phone and server always run the same code version; the engine version string is checked on both sides.

---

## 13. Claude integration
- Swift client calling the **Anthropic Messages API** directly (`https://api.anthropic.com/v1/messages`) with tool use. API key entered in Settings and stored in the **Keychain** only. Model is a setting (default `claude-sonnet-5-5`; verify current model names in Anthropic's docs).
- **Tools** (implemented in Swift as read-only SQLite queries; return compact JSON; cap results, bucket long series). No tool can read `raw_chunks` or `raw_minute_features`.
  | Tool | Input | Returns |
  | --- | --- | --- |
  | `list_available_data` | — | labels and date ranges present; inference kinds present |
  | `get_inferences` | kind, start, end | inference rows (non-superseded) |
  | `get_daily_summary` | date | sleep, activity_day, places visited, screen events, wind-down plan/outcome |
  | `get_series` | label, start, end, bucket (5m/15m/1h/1d), agg (avg/sum/min/max) | bucketed processed series |
  | `get_sleep_nights` | start, end | per-night onset, wake, duration, stage minutes, latency |
  | `get_visits` | start, end | visits with place names and durations |
  | `get_screen_events` | start, end | threshold crossings |
- Tool loop: max 8 tool rounds per question; total tool output per question capped (~50k characters); log everything to `ai_log` (question, tool calls + arguments, response, tokens, errors).
- System prompt for Claude (store in code, editable later):
  > You are Fengshui, a personal assistant that helps one person understand patterns in their own health, activity, sleep and daily context. Use the tools to fetch only the data you need. Base every statement on returned data and say which data you used. If data is missing or thin, say so. Don't diagnose medical conditions; suggest seeing a professional for anything concerning. Be concise and practical.
- **Preset questions** in `ai_questions`, seeded with three dev questions: "How did I sleep this week compared with last week?", "When should I start winding down tonight, and why?", "How active was I today?" The user can add, edit, disable and schedule their own. Scheduled questions run in a background task and deliver the answer as a notification that opens the full answer.
- A chat screen for free-form questions.

---

## 14. Testing strategy and phased plan

You test everything you can **without my devices** as you build. Real-device behaviour (sensors, permissions, background wake-ups, battery) is checked once, at the end, by me (section 16). Write the details of this strategy into `docs/TEST_STRATEGY.md`.

### 14.1 Where each kind of test runs

| Layer | What it covers | Runs on |
| --- | --- | --- |
| Python unit | engine, Health importer, raw codec, server | Mac, project venv (`pytest`) |
| Swift package unit | FengshuiKit: `minute_id`, raw encoder, preferences, schema | Mac (`swift test`) |
| iOS unit + integration | database, HealthKit sync logic, places, notifications scheduling, embedded Python, Claude tool loop | iOS Simulator, iPhone 17 Pro, iOS 26 (`xcodebuild test`) |
| watchOS unit | tier logic, harvesting, encoding, transfer queue | watchOS Simulator (watchOS 10 runtime if Xcode 27 can install it; otherwise the oldest available — note which in PROGRESS.md) |
| UI end-to-end | onboarding → backfill → Today → Ask → Settings | iOS Simulator, XCUITest, in test mode (below) |
| Phone ↔ watch | file transfer, acknowledgment, deletion | paired iPhone + Watch simulators (fall back to a fake transport if simulator transfer is unreliable; document it) |
| Phone ↔ server | sync, archive, retrieval, remote compute | iOS Simulator → server running on this Mac |
| Real data | engine on my exported Health data | Mac, against `~/Desktop/HealthExport/fengshui_health.sqlite` |

**Design for testability (required):**
- Every Apple-framework dependency sits behind a Swift protocol with a real implementation and a fake: HealthKit store, location manager, iPhone motion history, watch sensors (`CMSensorRecorder`, device motion, altimeter), WatchConnectivity, notification center, battery state, clock, network/Anthropic client.
- Watch sensor fakes replay synthetic or recorded traces (realistic noise, walking/running cadence, stillness, pressure changes) so the whole raw pipeline runs in the simulator.
- A launch argument `-FengshuiTestMode <scenario>` makes the app use fakes loaded with a named scenario (`new_user`, `typical_week`, `no_watch_data`, `shift_worker`, `sparse_data`), so UI tests never hit system permission dialogs.
- One synthetic data generator (`engine/tests/synth.py`) writes scenario files to `fixtures/scenarios/`; Swift fakes load the **same** files, so Python and Swift tests run on identical days.
- Tests are deterministic (fixed clocks, seeded randomness). `scripts/test_all.sh` runs every layer and prints a pass/fail summary table; aim for under 10 minutes.

**Simulators and disk:** check free disk space before downloading simulator runtimes (the disk is 256 GB), install only what you need, delete unused runtimes, and report disk use in PROGRESS.md.

**Test data I've provided:** I've included a separate set of test data you can use whenever it helps. Find it at the start (check the repo, especially any `test_data/`, `testdata/` or `fixtures/` folder, and `~/Desktop`); if you can't find it, add "where is your test data?" to your upfront questions. Then:
- Inspect it and describe its format, contents and date range in `docs/TEST_STRATEGY.md`.
- Use it wherever it makes tests more realistic: importer tests, scenario files, engine and wind-down checks, UI test scenarios, the Claude smoke test.
- Treat it as private unless it's clearly synthetic: don't copy it into the repo or push it until you've confirmed with me that it contains no real personal data.
- It's optional: don't let any test depend only on it — the synthetic generator must still cover every case.

**Real-data check** (whenever the Health export exists): run the engine over my Desktop database and write a local-only report `~/Desktop/HealthExport/engine_check.md` — share of minutes labelled `unknown`, detected bouts vs. logged workouts (precision/recall via `calibrate.py`), wind-down plans for the last 30 nights vs. actual sleep, any errors. Put only pass/fail and percentages (no health values) in PROGRESS.md. Adjust thresholds only when clearly off, and log every change in DECISIONS.md.

**If my iPhone happens to be connected and unlocked** (`xcrun devicectl list devices`), also install and run the unit tests that need no permissions on it. Never wait for this.

**On-device Diagnostics (for the final test):** build Settings → Diagnostics, which runs self-checks on the real device — permissions granted, HealthKit types readable, background delivery registered and firing, last sync per type, watch reachable, raw coverage in the last 24 h, engine run OK, tonight's notification scheduled, server reachable, Claude key present, signing expiry date — and uploads the result as JSON to the Mac server (`POST /diagnostics`, stored in `server/diagnostics/`, gitignored) so you can read it while I test.

### 14.2 Phases and their test gates

A phase is done only when its gate passes along with every earlier gate.

**Phase 0 — Foundations**
- Build: repo, XcodeGen project with iPhone and Watch targets, FengshuiKit, automatic signing with my Personal Team via the gitignored xcconfig (section 1a). Capabilities/entitlements: HealthKit (+ background delivery), Background Modes (background fetch, processing, location updates only if visit monitoring requires it), App Groups, Keychain; Watch: HealthKit, workout-processing background mode. **No Family Controls yet.** All Info.plist usage strings (Health share/update, Location always/when-in-use, Motion, Local Network). Protocols + fakes skeleton, scenario fixtures, `scripts/test_all.sh`.
- Spike A — embedded Python: call `fengshui_engine.version()` and a small SQLite read from Swift.
- Spike C — raw encoding: Swift encoder, Python decoder, shared fixtures.
- **Gate:** project regenerates cleanly from `project.yml`; both apps build for the simulator and the iPhone app launches; an XCTest in the simulator calls the embedded engine and reads SQLite; codec round-trip tests pass in Swift and Python on the same fixtures (including Apple raw-DEFLATE → `zlib.decompress(data, -15)`). Record the app-size increase and Python start-up time. If a device is connected, confirm the Personal Team can sign for it; otherwise list it for the final test.

**Phase 1 — Database + HealthKit**
- Build: schema and migrations (Swift + Python), onboarding permission flow, backfill with progress, incremental sync, deletions, background delivery with launch/refresh fallback, debug screen (row counts per label, last sync per type), Task B importer.
- **Gate:** a Python test opens a database created by the Swift migrations and passes the engine's schema check; label mapping is tested against every HealthKit identifier in the iOS 26 SDK; backfill/incremental tests with the fake store cover batching, resuming after interruption, anchors and deletions; importer tests pass on the synthetic `export.xml`, and its output passes the engine's schema check; a UI test runs onboarding → backfill progress → debug counts in test mode.

**Phase 2 — Context**
- Build: places onboarding (Home, Work, others), visits, geofences, place-suggestion UI, iPhone motion import. (Screen Time waits for the paid account.)
- **Gate:** visit-to-place matching, place-suggestion clustering (Python), geofence registration with the fake location manager, motion import idempotence, and a UI test of places onboarding all pass.

**Phase 3 — Watch**
- Build: preferences screen and sync to the watch, tiers 1–3, battery guard, complication, encoding, hourly file container, transfer + acknowledgment, import on the phone.
- **Gate:** tier logic with fake sensors (re-arming, harvest watermark, battery guard, snapshot time budget); transfer, acknowledgment and deletion between paired simulators (or the fake transport); phone import is idempotent; compression ratio measured on realistic synthetic 50 Hz traces (the real ratio is measured in the final test).

**Phase 4 — Engine**
- Build: `features`, `activity`, `wind_down`, `wind_down_outcome`, `place_suggestions`; embedded runs from Swift in background tasks; engine-run log in the debug screen.
- **Gate:** pytest suites for every task, including the worked wind-down example in 10.2 and golden fixtures; the same scenario run through embedded Python in the simulator produces **identical** inference rows to the Mac run; a performance test records how long one day of 50 Hz feature extraction takes in the simulator; the real-data check runs if the export exists.

**Phase 5 — Notifications**
- Build: planned and place-triggered prompts, logging, delay measurement.
- **Gate:** with a fake clock, plans schedule, reschedule (when superseded by > 5 min) and cancel correctly; the Home-arrival rule fires only when it should; a simulator test confirms the pending notification request has the right trigger time; log rows are written.

**Phase 6 — Server**
- Build: FastAPI app, sync, archive/retrieve, remote compute, compute-location setting, Bonjour, `/diagnostics`.
- **Gate:** API tests for auth, sync idempotency, byte-exact archive retrieval, and compute parity (server results equal phone results for the same scenario); a live integration test starts the server on this Mac and has the simulator app sync, archive, retrieve and run remote compute.

**Phase 7 — Claude**
- Build: Keychain key entry, tools, tool loop, preset questions + scheduling, chat UI, `ai_log` viewer.
- **Gate:** each tool's output is tested on a scenario database; a test proves no tool can read `raw_chunks` or `raw_minute_features`; the tool loop is tested with a mocked API (several rounds, caps, errors, logging); a privacy test scans every request body built in tests for raw-table fields. **Live smoke test only if `ANTHROPIC_API_KEY` is set in the environment:** ask the three preset questions against a synthetic scenario database (never my real data) with the cheapest current model, and record pass/fail and token use.

**Phase 8 — Hardening and handover**
- Build: error handling, retries, data export (copy the SQLite DB to Files), the Diagnostics screen and upload, privacy review (no raw-data path to Claude, no secrets in logs), README with setup steps.
- **Gate:** `scripts/test_all.sh` is fully green (apart from documented expected failures); then do section 16.

---

## 15. UI (keep it simple, SwiftUI)
- **Onboarding:** welcome → Health permissions → recording preferences → places (Home, Work, others) → sleep questions (wake times, bedtime) → Screen Time (only when `FENGSHUI_PAID_ACCOUNT` is on) → notifications permission → backfill progress.
- **Today:** tonight's wind-down plan (with reasons), today's activity timeline (bouts), quick stats.
- **Ask:** preset questions + chat.
- **Settings:** recording preferences, places, compute location, server URL/token, Claude key/model, wind-down overrides (tomorrow's wake time, wind-down length), debug section (table counts, sync state, engine runs, notification log, raw coverage, export DB).
- **Watch:** status (recording tiers on/off, last sync), start/stop session, minimal complication.

---

## 16. Handover and my final device test

When every gate passes:
1. Merge to `main`, tag `v0.1-poc`, push.
2. Write **`docs/FINAL_REPORT.md`**: what was built; test results per phase (passed / failed / expected failures); everything that could **not** be tested without my devices; known risks; the real-data check summary; disk and app-size numbers.
3. Write **`docs/DEVICE_TEST_CHECKLIST.md`**, in plain language for a non-expert, with the expected result for every step and what to do if it fails:
   - Turn on Developer Mode on the iPhone and the watch; connect them; install both apps (provide `scripts/install_on_devices.sh` if it helps).
   - Onboarding, all permission prompts, places, sleep questions, backfill.
   - Run Settings → Diagnostics (uploads to the Mac server).
   - Confirm on the real devices: HealthKit background delivery on the Personal Team, signing-expiry display, watch install on watchOS 10.6.2, sensor recording, transfer to the phone, real compression ratio.
   - Wear both for 3 days: what to look at each day, when to run Diagnostics again.
4. Send me a push notification that the build is ready for my test.

While I test, stay available over Remote Control: read my Diagnostics uploads from the server, fix what fails, re-run the gates, push, and tell me what to reinstall.

**Definition of done (after my device test):**
- A fresh install on my devices completes onboarding and backfill.
- Over 3 days of normal wear: raw accelerometer coverage reported; activity bouts look plausible against my memory and logged workouts; a wind-down notification fires each night within 5 minutes of its plan; Claude answers the three preset questions using only tool data; raw chunks older than 7 days are archived to the Mac and retrievable.
- `scripts/test_all.sh` is green; `docs/PROGRESS.md` and `docs/FINAL_REPORT.md` give measured numbers (compression ratio, notification delay, battery).

Start by reading this whole file. Then send me your upfront questions (section 0) in one message, and get going.
