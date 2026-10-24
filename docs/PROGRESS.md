# Progress

## Status

| Phase | State | Gate |
| --- | --- | --- |
| Plan | done | — |
| 0 Foundations | done (tag `phase-0`) | PASS |
| 1 Database + HealthKit | done (tag `phase-1`) | PASS |
| 2 Context | done (tag `phase-2`) | PASS |
| 3 Watch | — | — |
| 4 Engine | — | — |
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
