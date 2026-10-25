# Progress

## Status

| Phase | State | Gate |
| --- | --- | --- |
| Plan | done | — |
| 0 Foundations | done (tag `phase-0`) | PASS |
| 1 Database + HealthKit | done (tag `phase-1`) | PASS |
| 2 Context | done (tag `phase-2`) | PASS |
| 3 Watch | done (tag `phase-3`) | PASS |
| 4 Engine | done (tag `phase-4`) | PASS |
| 5 Notifications | — | — |
| 6 Server | — | — |
| 7 Claude | — | — |
| 8 Hardening | — | — |

## Blocked / waiting on owner

| Item | Needed for | Workaround |
| --- | --- | --- |
| GitHub: `gh` not installed / authenticated; repo visibility unchecked | pushing | owner deferred; local commits and tags |
| Homebrew not installed | — | repo-local tools (D-01) |
| Xcode not signed in to an Apple Account (no Team ID) | device builds only | simulator builds need no team |
| `ANTHROPIC_API_KEY` not set | Phase 7 live smoke test | mocked API tests run anyway |
| Test data reality not confirmed | committing anything derived from it | treated as private |

## Log

### 2026-10-24
- Checked the environment: Xcode 27.0, macOS 27.0, 125 GB free. No Homebrew, gh or Python 3.13. Health export present on the Desktop.
- Repo-local Python 3.13.17 and XcodeGen 2.46.0; `.venv` created.
- Local git repo, `.gitignore`, secret-check pre-commit hook.
- Started the iOS 26.0 simulator runtime download (7.99 GB).
- Wrote PLAN, TEST_STRATEGY and DECISIONS.

### Phase 0 — Foundations (2026-10-24)
**Built:** XcodeGen project (`Fengshui` iOS 26, `FengshuiWatch` watchOS 10 embedded in `Fengshui.app/Watch`, unit/UI/watch test targets), `FengshuiKit` package (`MinuteID`, `RawCodec`, `ExportKey`, `Schema`, `Clock`), entitlements (HealthKit + background delivery, App Group, Keychain; watch: HealthKit, App Group, workout-processing), all usage strings, `Shared.xcconfig` + gitignored `Local.xcconfig`, `FENGSHUI_PAID_ACCOUNT` flag (off). Embedded CPython via C shim (`PythonBridge.c`) and `fengshui_engine.bridge`. `scripts/bootstrap.sh`, `build_python_ios.sh`, `test_all.sh`, `check_secrets.sh`.

**Gate results:**
| Check | Result |
| --- | --- |
| Project regenerates from `project.yml` | PASS |
| iPhone + Watch apps build for the simulator; iPhone app launches (XCUITest) | PASS |
| XCTest in the simulator calls the embedded engine (`version()`) and reads a SQLite DB created by Swift; `zoneinfo` works with the bundled tzdata | PASS |
| Codec: Swift pack == Python pack byte-for-byte (9 vectors incl. int16 wrap, gaps, empty); Apple `COMPRESSION_ZLIB` output decodes with `zlib.decompress(data, -15)`; Python output decodes in Swift | PASS |
| Personal Team can sign for the device | not testable (no device connected, Xcode not signed in) → final device test |

**Measurements:**
- Python start-up in the simulator: **0.035 s** (`Py_InitializeFromConfig` + `site.addsitedir`); later bridge calls take < 1 ms.
- App size (simulator debug build): **56 MB** in total, of which embedded Python is about **45 MB** (stdlib 11 MB, `app_packages` 2.6 MB with tzdata as most of it, Python.framework 11 MB, ~70 extension-module frameworks). The simulator slice is fat (arm64 + x86_64), so the device build will be smaller; it gets measured in the final test.
- Simulators: iPhone 17 Pro / **iOS 26.0**; Apple Watch SE 3 (44 mm) / **watchOS 26.0**. That's the oldest runtime Xcode 27 offers: 10.5, 11.0 and 11.5 are "not available for download" (D-09).
- Disk: 103 GB free after the iOS 26.0 + watchOS 26.0 runtimes (11 GB + ~10 GB).

**Deferred to their phases:** the protocol + fake set grows per phase (Clock now; HealthKit in Phase 1, location/motion in 2, watch sensors and transport in 3, notifications in 5, network in 6–7). Scenario fixtures arrive with `synth.py` in Phase 1.

### Phase 1 — Database + HealthKit (2026-10-24)
**Built:** GRDB `AppDatabase` (WAL, busy_timeout 5000, FKs) whose migrator executes the shared `schema_v1.sql`; `HealthStore` protocol with `HKHealthStoreAdapter` (anchored queries, workouts + routes, heartbeat series, ECG, state of mind, scored assessments, characteristics, preferred units with header-derived fallbacks, observer queries + `.immediate` background delivery) and `FakeHealthStore`; `HealthSync` actor (5,000-row pages, one transaction per page with its anchor, resumable, deletions → `deleted = 1`); `ExportAdoption` (D-06); `BackgroundDelivery` for the six spec types, plus the fallback on launch, foreground, `BGAppRefreshTask` and `BGProcessingTask`; onboarding (welcome → Health → backfill progress), Settings → Debug (counts per label, tables, last sync per type, event log); `-FengshuiTestMode <scenario>` with bundled synthetic scenarios. HealthKit catalog of 204 types generated from the SDK headers (D-10). Task B importer.

**Gate results:**
| Check | Result |
| --- | --- |
| Python opens a DB created by the Swift migrations and passes the engine schema check (in the simulator via embedded Python, and on the Mac via `test_swift_db.py`, with table SQL identical) | PASS |
| Label mapping matches the Python reference for all 204 iOS ≤ 26 SDK identifiers, plus 86 workout activity names | PASS |
| Fake-store sync: batching (11 pages / 1,050 rows), resume after interruption (no refetch, no duplicates), anchors, incremental, deletions, routes, characteristics, export-row adoption, background-delivery wake | PASS |
| Importer on the synthetic `export.xml` (records, categories, HRV beats, correlation, workout + GPX route, `<Me>`, activity summary, duplicates, bad dates, re-import, newer export, `--csv`, zip untouched); output passes the engine schema check | PASS (13 tests) |
| UI test: onboarding → backfill progress → debug counts (test mode) | PASS |

**Real export (Task B):** imported locally to `~/Desktop/HealthExport/fengshui_health.sqlite`: 38 labels, no warnings, about 100 s, peak memory 124 MB (streaming confirmed on a 1.2 GB `export.xml`). A re-import added 0 rows (PASS). Nothing derived from it is in the repo.

**Bug found by the UI test and fixed:** a Swift exclusivity violation when backfill finished (read and write of the same `@Observable` property in one statement), plus a race where a late progress update could overwrite the finished state. Completion now has its own flag.

### Phase 2 — Context (2026-10-24)
**Built:** `LocationProvider` protocol with `CoreLocationProvider` (visit monitoring, significant-location-change, one-shot `requestLocation` for "use current location", geofences through `CLMonitor` with `CircularGeographicCondition`, re-created by name at launch so region events relaunch the app) and `FakeLocationProvider`; `PlaceService` (Home/Work replace-in-place, custom places, nearest-within-radius matching, re-matching visits when places change, open/close visit handling, Home-entry hook for wind-down, max 20 geofences, idempotent start); `MotionHistory` (`CMMotionActivityManager` → merged segments) + `MotionImporter` (since the last stored segment, 7-day first look-back, upsert on `(start_ts, activity)`, runs after every sync); engine task `place_suggestions` (greedy 150 m clustering of unmatched visits ≥ 5 min, ≥ 3 visits, skips covered or dismissed spots); `config.py`; per-task transactions in the engine runner; places onboarding step and Settings → Places with a MapKit pin drop, radius and suggestions (name / dismiss). Screen Time: deferred (paid account).

**Gate results:**
| Check | Result |
| --- | --- |
| Visit-to-place matching (Swift + Python helper, same rule) | PASS |
| Place-suggestion clustering (Python): finds the synthetic gym + café in `typical_week`, idempotent, respects dismissals, ≥ 3 visits, ignores pass-throughs | PASS (6 tests) |
| Geofence registration with the fake location manager (add, replace Home, suggestions not monitored, delete) and the Home-entry hook | PASS |
| Motion import idempotence (re-import, open segment closed later, incremental window) | PASS |
| UI test: places onboarding (Home, Work, custom place) → backfill → debug → places listed in Settings | PASS |

### Phase 3 — Watch (2026-10-24)
**Built:** `RecordingPreferences` (onboarding step + Settings → Recording, sanitized, mirrored with `updateApplicationContext`); all watch logic in FengshuiKit so it runs in every test layer: `MinuteChunker` (per-minute chunks, gap detection), `ChunkContainer` (FSC1 hourly file = JSON index + fsr1 payloads), `WatchRecorder` (tier 1 re-armed on every wake + harvest from a watermark of complete minutes, 2-minute lag, at most 6 h per wake, retention-limited first run; tier 2 snapshot when due, battery guard < 30 % / Low Power Mode, shortened or skipped to fit the time budget; outbox deleted only after the ack, stale files resent after 6 h; recorder gaps logged in the container, not worked around), `SessionAssembler` (tier 3), `Compass` (tilt-compensated heading from magnetometer + gravity). Watch target: `CMSensorRecorder` adapter, snapshot adapter (device motion + magnetometer + altimeter, **no location**, D-11), `HKWorkoutSession(.other)` + live builder for HR in sessions, WCSession link (files out; prefs + acks in), `WKApplicationRefreshBackgroundTask` handling at the chosen interval, status UI with session start/stop, ClockKit complication (D-07). Phone: `WatchImporter` (upsert on `(minute_id, sensor, tier)`, archived rows untouched, gap log), `WCPhoneLink` (copies the file, imports, acknowledges with `transferUserInfo`), `FakeWatchLink`.

**Owner request handled:** the watch doesn't use location at all. Its compass comes from the magnetometer, and all location context comes from the iPhone (D-11).

**Gate results:**
| Check | Result |
| --- | --- |
| Tier logic with fake sensors: re-arm every wake, harvest watermark (incremental, unchanged on failure), per-wake cap, battery guard (29 %, LPM, 30 % OK), snapshot interval + time budget (shortened 8 s → 4 s; skipped below 3 s), sensors off → no tier 1 | PASS (Mac `swift test` **and** the watchOS 26 simulator) |
| Transfer → phone import → ack → watch deletes (in-process loopback transport; simulator WatchConnectivity not used, see TEST_STRATEGY) | PASS |
| Phone import idempotent; archived minutes not overwritten; gap log kept | PASS |
| Preferences mirrored to the watch | PASS |
| Compression ratio, synthetic 50 Hz trace (desk / walk / run): **3.08× vs float32**, 1.54× on top of int16 packing | measured |
| Compression ratio, owner's real Sensor Logger watch recordings (local only, resampled to 50 Hz): **3.18–3.52× vs float32**, about 10 KiB/min (~14 MB/day of tier 1) | measured |
| Watch app builds for watchOS 10 target; complication compiles (ClockKit) | PASS |

### Phase 4 — Engine (2026-10-24)
**Built:** `features` (ENMO, SD, autocorrelation cadence, active fraction, barometric vertical speed, heading change, gyro RMS; incremental by `received_at`), `activity-v1` (per-minute evidence, documented scoring in `docs/ALGORITHMS.md`, O(n·labels) Viterbi with fixed workout/sleep overrides, minimum bouts, HRR intensity, place context incl. "near Work" and commute from/to, confidence, provisional + supersede, daily summaries), `sleep` nights, `wind_down` + `wind_down_outcome` (`wind_down-v1`, the spec's arithmetic in `compose()`, circular medians, day type, override, need/debt, guards, evening adjustments incl. not-home / Screen Time reasons, supersede only on > 5 min moves, learning of wind-down length), `place_suggestions`; all constants in `config.py`. Embedded runs: `EngineRunner` actor (serialized, logged in the debug screen with "Run engine now"), triggered by HealthKit deliveries, foreground, `BGAppRefreshTask` (light tasks), `BGProcessingTask` (all), watch imports, visits and Home arrival. Tools: `engine/tools/calibrate.py`, `scripts/real_data_check.py`, `engine/tests/eval_scenario.py`, canonical dump (`fengshui_engine.dump`).

**Gate results:**
| Check | Result |
| --- | --- |
| pytest for every task (108 Python tests total): features (cadence per activity, exact ENMO, snapshots, late chunks, tier 3, archived), activity (Viterbi, min bouts, details, days, incremental/idempotent, golden fixture `fixtures/golden/activity_typical_week.json`), wind-down (**the spec's worked example: 23:41 / 23:27 / 22:12**, guards, cap, circular medians, workday/free/shift/cold start, override, adjustments + supersede, not-home, outcomes + learning ±15 min), calibration | PASS |
| Agreement with synthetic ground truth (minutes): typical_week 95.7 % (raw-data days 99.7 %), no_watch_data 94.5 %, shift_worker 99.6 % (99.9 %), sparse_data 95.2 % (100 %). watch_off is detectable only with accelerometer data (spec rule), which accounts for most of the remaining all-days error | PASS (thresholds in `test_activity.py`) |
| Same scenario through embedded Python in the simulator gives **identical** inference rows, feature digest and engine state as the Mac run | PASS |
| Performance: one day of 50 Hz feature extraction ≈ **3.8 s in the iOS simulator** (2,288 minutes in 6.1 s), ≈ 3 s on the Mac; activity over 14 days ≈ 0.1 s | measured |
| Real-data check (local `engine_check.md`) | ran, no errors |

**Real-data check summary (owner's export, last 30 days; percentages only):** unknown minutes 0.2 %. Walking recall inside the owner's Apple Watch walking workouts 62 % (export has no phone motion or raw data, so steps + HR only). Auto-detected Oura "walking" workouts aren't walks (D-15). Cycling is undetectable without phone motion or raw data (3 short workouts). Wake prediction within 30 min on 70 % of nights, mean absolute error 50 min. Plans were "followed" (in bed within 30 min of target) on 24 % of nights. The learning step shortened wind-down to 30 min (short measured latencies). Thresholds changed: only the multi-source step fix (D-14), which is a bug fix, not tuning.
