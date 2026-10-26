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
| 5 Notifications | done (tag `phase-5`) | PASS |
| 6 Server | done (tag `phase-6`) | PASS |
| 7 Claude | done (tag `phase-7`) | PASS (live smoke test not run: no key) |
| 8 Hardening | done (tags `phase-8`, `v0.1-poc`) | PASS |

## Blocked / waiting on owner

| Item | Needed for | Workaround |
| --- | --- | --- |
| GitHub: `gh` not installed / authenticated; repo visibility unchecked | pushing | owner deferred; all work committed locally on `main` with tags (push steps in FINAL_REPORT) |
| Homebrew not installed | — | repo-local tools (D-01) |
| Xcode not signed in to an Apple Account (no Team ID) | device install (DEVICE_TEST_CHECKLIST A1–A2) | simulator builds need no team |
| `ANTHROPIC_API_KEY` not set | Phase 7 live smoke test | mocked API tests pass; run `scripts/claude_smoke_test.sh` once the key is in your shell |
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

### Phase 5 — Notifications (2026-10-24)
**Built:** `NotificationCenter` protocol (UNUserNotificationCenter + fake); `WindDownScheduler` (calendar trigger at `wind_down_start` in the local time zone, identifier `wind_down_<night_of>`, rescheduled when the engine supersedes the plan, cancelled when reminders are switched off, never scheduled in the past; Home-arrival prompt `wind_down_home_<night_of>` once per night within 90 min after the start unless tonight's prompt was dismissed; every schedule / cancel / delivery written to `notifications_log`; delay = delivered − scheduled); engine runs call it after every run; app delegate records `willPresent`, taps and dismissals (custom dismiss action), and the delivered list is reconciled on foreground. Signing expiry: reads `embedded.mobileprovision`, Settings shows "Signing expires in N days", and a reminder is scheduled 1 day before. Onboarding now has every non-paid spec step: welcome → Health → recording → places → **sleep questions** → **notifications** → backfill. **Today** screen (tonight's plan with explanations, today's bouts, quick stats; refreshes after each engine run). Settings → Wind-down (reminders on/off, tomorrow's wake override, wind-down length; the length is a preference the engine applies once, so it keeps ownership of `engine_state`). Notification log screen with delays.

**Gate results:**
| Check | Result |
| --- | --- |
| Fake clock: schedule at start + log row; idempotent; reschedule on supersede with the old log row cancelled; cancel when disabled; nothing scheduled in the past; next night gets its own identifier | PASS |
| Home-arrival rule: not before start, not > 90 min after, once per night, suppressed after dismissal | PASS |
| Delivery delay measured from the delivered list (42 s case) | PASS |
| **Simulator, real UNUserNotificationCenter:** pending request's calendar trigger == wind-down time (± 0.5 s). Permission is granted by `NotificationPermissionUITests` because `simctl privacy` has no notifications service | PASS |
| Signing profile parsing + reminder 1 day before | PASS |
| UI: full onboarding → Today shows tonight's plan | PASS |

**Bug fixed:** Today didn't refresh when the post-onboarding engine run finished, so it showed no plan until reopened. It now listens for `engineDidRun`.
**Not testable here:** actual delivery delay on the device, which is measured in the final test via the log. Time-sensitive interruption level is not used (needs an entitlement that may not exist on a Personal Team).

### Phase 6 — Server (2026-10-24)
**Built:** `server/fengshui_server` (FastAPI): bearer auth with constant-time comparison, engine-version check (409), `/health`, `/sync` (natural-key upserts, deletion list, export-row adoption, devices table), `/raw/archive` (blobs unchanged, partitioned by day), `/raw` (base64 + sha256), `/compute` (engine `where="server"`, returns new/superseded rows, features and engine state), `/diagnostics` + `/diagnostics/latest`, Bonjour `_fengshui._tcp`. `scripts/run_server.sh` generates the token into gitignored `server/.env` on first run; optional launchd plist. Phone: `KeychainStore` (token; after-first-unlock, this device only), `ServerClient`, `ServerSync` (incremental watermarks in `server_sync_state`, re-sent mutable rows, Wi-Fi only via `NWPathMonitor`, archive of chunks older than 7 days with payload cleared only for confirmed refs, byte-exact retrieve, remote compute), compute location phone/server/auto in `EngineRunner` (auto = Low Power Mode or > 24 h raw backlog, and reachable; falls back to the phone on failure), Bonjour discovery (`NWBrowser`) + manual URL, Settings → Server & compute, nightly archive + sync in `BGProcessingTask`.

**Gate results:**
| Check | Result |
| --- | --- |
| API tests: auth (missing / wrong / no "Bearer"), version mismatch, unknown table, sync idempotency (row counts unchanged on re-sync), deletions, export adoption, byte-exact archive retrieval + sha256, idempotent re-archive, **compute parity** (server rows == phone rows for `typical_week`, incl. features + engine state), diagnostics, Bonjour startup | PASS (12) |
| Phone unit tests (stub server): watermarks, Wi-Fi only, partial archive confirmation, errors, compute-location choice, fallback to phone, Keychain | PASS |
| **Live:** server started on this Mac, simulator app syncs (16k samples, then 0 on re-sync), runs remote compute (result identical to the Mac reference dump), archives 2,000+ chunks 8 days later, retrieves them byte-for-byte | PASS (`scripts/live_server_test.sh`, now part of `test_all.sh`) |

**Bug fixed:** server startup hung with Bonjour on (sync zeroconf inside uvicorn's loop); covered by a regression test.

### Phase 7 — Claude (2026-10-24)
**Built:** `AnthropicHTTP` (Messages API, retries), `ClaudeTools` (7 tools of spec §13 over a read-only connection that refuses raw tables; compact JSON, capped rows / buckets / 12k chars per result), `ClaudeAssistant` tool loop (max 8 rounds then a budget notice, ~50k tool characters per question, refusal / max_tokens / errors handled, everything logged in `ai_log`), preset questions (3 dev seeds; add / edit / disable / schedule `daily:HH:MM` or `weekly:day:HH:MM`; scheduled ones run in `BGAppRefreshTask` and the answer arrives as a notification), Ask tab (presets + chat), Settings → Claude (Keychain key, model) and the `ai_log` viewer. Model choices and API details: D-17.

**Gate results:**
| Check | Result |
| --- | --- |
| Each tool's output on the synthetic `typical_week` DB (labels, bouts incl. "near Work", daily summary, hourly HR / daily steps, 7 nights, visits by name, empty Screen Time with note) + input errors and size caps | PASS |
| **No tool can read `raw_chunks` / `raw_minute_features`**: SQL naming them is refused, the connection is read-only, and no tool output contains raw fields | PASS |
| Tool loop with a mocked API: 3 requests, parallel tool results in one user turn, thinking block passed back unchanged, tokens summed, `ai_log` row; 8-round cap; ~50k output cap; HTTP 401, refusal, unknown tool | PASS |
| Request shape: model, `tool_choice` auto, no temperature, fallbacks + beta for Sonnet / none for Haiku, headers + `anthropic-version` + retry on 529 | PASS |
| **Privacy scan** of every request body built in the tests: no raw-data field names | PASS |
| Scheduling (parse, first-sight, catch-up once, disable, DST week) + scheduled answer delivered as a notification | PASS |
| Live smoke test (three preset questions, `claude-haiku-5-5`, synthetic DB) | **not run**: `ANTHROPIC_API_KEY` is not set in the shell. `scripts/claude_smoke_test.sh` runs it (and `test_all.sh` adds it automatically) once it is |

### Phase 8 — Hardening and handover (2026-10-24)
**Built:** Settings → Device test → **Diagnostics** (≈ 35 self-checks: HealthKit types / data / backfill / last sync per background-delivery type / observers registered and fired, Always location, geofences, visits, phone motion, watch paired / reachable, raw coverage 24 h, real compression ratio, recorder gaps, snapshots, compass, engine last run, tonight's notification, notification delays, server, Claude key, signing expiry; metrics incl. app bundle size, DB size, battery, unadopted export rows), uploaded as JSON to `POST /diagnostics` (readable with `GET /diagnostics/latest`); **Export database** (SQLite online backup → ShareLink / Files); Release builds strip the synthetic scenarios; unsigned device builds work (ad-hoc signing for the Python extension frameworks) so size can be measured; `test_all.sh` cleans test DB copies from the simulator; README, `PAID_ACCOUNT_SWITCH.md` (incl. Spike B), `install_on_devices.sh`, `DEVICE_TEST_CHECKLIST.md`, `FINAL_REPORT.md`.

**Privacy review:** raw watch data has no path to Claude (read-only connection refusing raw tables + tool-output and request-body scans in tests). Secrets never appear in the event log, preferences or Diagnostics JSON (tested). The token and key are Keychain-only. The pre-commit hook blocks key-shaped strings: it caught a test fixture and rejected the commit, and the fixture was changed rather than the hook. Visits go to Claude without coordinates. The watch uses no location.

**Gate:** `scripts/test_all.sh` fully green, 12 layers in 236 s, no expected failures. Release device build **45 MB** (12.9 MB zipped).

**Next:** the owner's device test (`docs/DEVICE_TEST_CHECKLIST.md`). Only the owner can do: sign in to Xcode and set the Team ID, Developer Mode on both devices, permissions, 3 days of wear.

### Device-test follow-up — Data tab (2026-10-25)
**Built:** Data tab with live database-driven updates, per-type detail pages, watch "send now" and live session heart rate (D-18). **Fixed:** Bonjour name clash when a second server, or a quick restart, registers the same name (`allow_name_change`); the CLMonitor is now shared per process, not per provider (the test host's provider and the test's provider clashed: "Monitor named FengshuiPlaces is already in use").

**Gate:** `scripts/test_all.sh --no-live` fully green (12 layers, 245 s). iOS unit 77 (5 new: snapshot units / per-source totals / sleep / watch coverage, empty DB, observation emits after a write, cumulative detail, unit normalisation); end-to-end UI test opens the Data tab and a heart-rate detail page.

### Phase 9 — Reports, inbox, server health monitor (2026-10-25)
**Built:** Reports tab: PDF for health professionals, AI label choice via `list_report_labels` / `propose_report_labels` and AI summary via `create_report`, filters by labels and date or range, share and delete; **a report for every Ask question**; "Ask FengShui Agent" title; notification inbox with a bell and badge, select, delete selected, delete after reading; server health monitor (sessions with a user-chosen interval and duration, rules first, Claude agent on flags, APNs client, best-effort gap stats, pull mode without the paid account); Settings → Health monitor. Decisions D-19 and D-20.

**Gate:** `scripts/test_all.sh --no-live` fully green (12 layers, 264 s). iOS unit 89 (12 new: inbox ingest / badge / delete-selected / delete-after-read; available labels by period; PDF content and page count; units and per-source totals; filter by labels, day and range; AI suggest then create with the user's filter enforced; question report scope; report tools read-only; monitor payload is processed data only, alerts filed once, due logic, pushed alerts not re-notified). Server 27 (15 new: each rule; agent called only on flags and able to decline; alert stored, pushed and listed; cooldown; hard rules override agent decline or failure, no downgrade; interval requests and gap coverage; session end summary; APNs request shape and ES256 token). End-to-end UI: Reports → PDF → bell badge → inbox select-all → delete → Ask title.

**Not testable here:** APNs delivery (needs the paid account and a .p8 key); a live Claude agent decision (needs a key on the Mac); silent-push throttling on a real device.

### MCP server (2026-10-25)
**Built:** `/mcp` on the Mac server (D-21). **Gate:** server tests 32 (5 new: auth required, initialize and tool list with read-only annotations, tools return processed data only, bad arguments become tool errors, raw-table guard). Also checked end to end with the official MCP client against a real uvicorn instance (synthetic data, port 8799): 7 tools listed, `list_available_data` answered.
