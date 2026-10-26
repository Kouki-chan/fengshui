# Fengshui v0.1 PoC: final report (2026-10-24)

## What was built

| Area | Delivered |
| --- | --- |
| iPhone app | HealthKit backfill + incremental sync (204 types from the SDK headers, anchored 5,000-row pages, resumable, deletions, background delivery for 6 types with launch / foreground / BGAppRefresh / BGProcessing fallback, export-row adoption); places (Home / Work / custom, visits, CLMonitor geofences, suggestions to name or dismiss); iPhone motion import; watch import + ack; embedded CPython 3.13 engine (`EngineRunner`, all spec §9 triggers, phone / server / auto); wind-down notifications (calendar trigger, reschedule, Home-arrival prompt, delivery log); Mac sync, 7-day raw archive, remote compute, Bonjour; Claude (7 read-only tools, tool loop with caps, preset + scheduled questions, chat, log); Today / Ask / Settings / Debug / Diagnostics / export; signing-expiry display + reminder; test mode with synthetic scenarios |
| Watch app (watchOS 10 target) | Tier 1 CMSensorRecorder 50 Hz (re-armed every wake, harvest watermark, gaps logged); tier 2 gyro / barometer / compass snapshots (battery guard, time budget); tier 3 sessions (HKWorkoutSession + device motion + altimeter + HR ~5 s); hourly FSC1 files via WCSession with delete-after-ack; ClockKit complication; **no location** (compass from magnetometer) |
| Engine (Python, same code on phone and Mac) | `features`, `activity-v1`, `wind_down-v1` + outcome learning, `place_suggestions`; all constants in `config.py`; scoring in `docs/ALGORITHMS.md` |
| Mac server | FastAPI: `/health`, `/sync`, `/raw/archive`, `/raw`, `/compute`, `/diagnostics`; bearer token; Bonjour; launchd plist |
| Tooling | `bootstrap.sh` (no system-wide installs), `test_all.sh`, Health-export importer, real-data check, calibration, compression check, install script, secret-check pre-commit hook |

## Test results per phase

`scripts/test_all.sh`: **every layer PASS** (final run below). There are no expected failures.

| Phase | Gate | Result |
| --- | --- | --- |
| 0 Foundations | project regenerates; both apps build; app launches; embedded engine called from an XCTest reads SQLite; codec cross-checked Swift ↔ Python incl. Apple raw DEFLATE → `zlib.decompress(data, -15)` | PASS |
| 1 Database + HealthKit | Swift-created DB passes the engine schema check; labels for all 204 SDK identifiers; batching / resume / anchors / deletions; importer on synthetic export; onboarding → backfill → debug UI test | PASS |
| 2 Context | visit matching, clustering, geofences with fake manager, motion idempotence, places UI test | PASS |
| 3 Watch | tier logic with fake sensors (Mac + watchOS simulator); transfer / ack / delete (loopback transport); idempotent import; compression measured | PASS |
| 4 Engine | pytest per task incl. the spec's worked wind-down example; golden fixture; **simulator embedded run == Mac run (identical rows)**; performance measured; real-data check run | PASS |
| 5 Notifications | schedule / reschedule (> 5 min) / cancel with fake clock; Home-arrival rule; real pending request trigger time in the simulator; log rows | PASS |
| 6 Server | auth, sync idempotency, byte-exact archive retrieval, **compute parity**; **live** simulator ↔ server (sync, archive, retrieve, remote compute) | PASS |
| 7 Claude | each tool on a scenario DB; no tool reads raw tables; mocked tool loop (rounds, caps, errors, logging); privacy scan of request bodies | PASS · live smoke test **not run** (`ANTHROPIC_API_KEY` not set; `scripts/claude_smoke_test.sh` when it is) |
| 8 Hardening | Diagnostics + upload, DB export, secrets never in logs or diagnostics, end-to-end UI (onboarding → backfill → Today → Diagnostics → Ask → Settings) | PASS |

Test counts: Python 121 (engine 96, importer 13, server 12) · FengshuiKit 26 (also run in the watchOS simulator: 16 watch suites) · iOS unit / integration 70 (+ 2 live tests that need a key or a running server) · UI 3 · live server 1.

## Measured numbers

| What | Value |
| --- | --- |
| Python start-up in the app (simulator) | 0.02–0.035 s; bridge call < 1 ms |
| App size, Release build for device (unsigned) | **45 MB** (12.9 MB zipped); embedded Python ≈ 34 MB of it (stdlib 11 MB, tzdata + engine 2.6 MB, Python.framework + ~70 extension modules ≈ 20 MB); watch app 1.3 MB |
| Features, one day of 50 Hz accelerometer | ≈ **3.8 s** in the iOS simulator, ≈ 3 s on the Mac |
| Compression (fsr1-i16-delta-deflate) | synthetic 3.08× vs float32; **owner's real watch recordings 3.18–3.52×** (~10 KiB/min, ~14 MB/day of tier 1) |
| Activity vs synthetic ground truth | 94.5–99.6 % of minutes over 14 days; 99.7–100 % on days with watch data |
| Real Health export | 2.81 M rows imported in 99 s at 124 MB peak memory; re-import adds 0 |
| Notification delivery delay, real devices | measured in the device test (Diagnostics / notification log) |
| Battery | measured in the device test |

## Real-data check summary (owner's export, local only; percentages only)

Unknown minutes 0.2 %. Walking recall inside Apple Watch walking workouts 62 % (the export has no phone motion and no raw data, so this runs on steps + HR only). Wake prediction within 30 min on 70 % of nights (MAE 50 min). The check found one real bug: **steps summed across devices**. Fixed by taking the per-source maximum (D-14). Auto-detected "walking" workouts from another app turned out not to be walks (median 0 steps/min), so they're excluded as ground truth (D-15). No thresholds were tuned.

## Not testable without your devices

- Signing with your Personal Team; installing on iOS 26.0.1 and **watchOS 10.6.2** (the simulators are iOS 26.0 and the oldest available watchOS, 26.0; Xcode 27 offers no watchOS 10 runtime, D-09).
- **HealthKit background delivery on a Personal Team** (the fallback is built in).
- Real sensors: CMSensorRecorder coverage and gaps, magnetometer availability on the SE (1st gen), barometer, session HR.
- Real WatchConnectivity file transfer (tests use a loopback transport; simulator transfer is unreliable).
- Background refresh frequency, with and without the complication.
- Real location: visits, CLMonitor relaunch on Home arrival, Always permission flow.
- Notification delay on the device; battery impact; real compression ratio on 24 h data; device app size when signed.
- Live Claude answers (needs your key).

## Known risks

1. **Background delivery on a free account** may not fire. Mitigation: the same sync runs on launch, foreground and background refresh.
2. **watchOS background budget:** tier-2 snapshots and harvest frequency depend on how often watchOS wakes the app. The complication helps.
3. **CMSensorRecorder gaps** (e.g. during watch-detected sleep): measured, not worked around (spec §7.1).
4. **ClockKit** is deprecated (kept to stay at two App IDs; WidgetKit with the paid account, D-07).
5. **7-day signing expiry:** reinstall weekly (a reminder is scheduled).
6. **Screen Time** waits for the paid account; Spike B may show the extension can't write to the App Group (`PAID_ACCOUNT_SWITCH.md`).
7. **Export-row adoption** relies on tolerant matching; unadopted `export:` rows are counted in Diagnostics.
8. Day type uses the Mon–Fri fallback until two weeks of visits exist (D-12).

## Environment, disk and deviations

- No Homebrew on this Mac: repo-local Python 3.13.17 and XcodeGen 2.46.0 in `.tools/` (D-01). Nothing system-wide was installed apart from the simulator runtimes you approved.
- **GitHub:** pushed on 2026-10-25 to the **private** repo `github.com/Kouki-chan/fengshui` (`main` plus tags `phase-0` … `phase-9`, `v0.1-poc`), after a full-history scan for private data (none found). `gh` lives in `.tools/gh/` (repo-local). To push later: `git -c "credential.helper=!$PWD/.tools/gh/bin/gh auth git-credential" push`, or run `.tools/gh/bin/gh auth setup-git` once to make that the default.
- Disk: 77 GB free (125 GB at the start). Attributed: simulator runtimes iOS 26.0 + watchOS 26.0 ≈ 11 GB (22 GB of runtimes in total), simulator data ≈ 5 GB, `build/` ≈ 2 GB, `~/Desktop/HealthExport` 3.6 GB (unzipped export + imported DB), repo tools + venv + Python-Apple-support ≈ 0.5 GB. The rest is Xcode / system caches I couldn't fully attribute. If space gets tight: `xcrun simctl runtime delete` for iOS 27 / watchOS 27 (unused, ≈ 11 GB), and `rm -rf build`.
- All deviations from the spec are listed in `docs/DECISIONS.md` (D-01 … D-17).
