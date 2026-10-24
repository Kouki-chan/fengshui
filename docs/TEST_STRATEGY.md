# Test Strategy

Everything that can run without the owner's devices is tested on this Mac. Real-device behaviour (sensors, permissions, background wake-ups, battery) is checked once, at the end, with `DEVICE_TEST_CHECKLIST.md`.

## Layers

| Layer | Covers | Runs on | Command |
| --- | --- | --- | --- |
| Python unit | engine, importer, raw codec, server | Mac, `.venv` | `.venv/bin/pytest engine/tests server/tests scripts/tests` |
| Swift package | FengshuiKit: `minute_id`, raw codec, prefs, schema | Mac | `swift test --package-path apple/FengshuiKit` |
| iOS unit + integration | DB, HealthKit sync logic, places, notification scheduling, embedded Python, Claude tool loop | iOS Simulator (iPhone 17 Pro, iOS 26.0 when installed; else iOS 27.0) | `xcodebuild test -scheme Fengshui` |
| watchOS unit | tiers, harvesting, encoding, transfer queue | watchOS Simulator (oldest available runtime) | `xcodebuild test -scheme FengshuiWatch` |
| UI end-to-end | onboarding → backfill → Today → Ask → Settings | iOS Simulator, XCUITest, `-FengshuiTestMode <scenario>` | part of `Fengshui` scheme |
| Phone ↔ watch | transfer, ack, deletion | in-process fake transport wired between the phone importer and the watch queue (simulator WatchConnectivity file transfer is unreliable) | iOS unit tests |
| Phone ↔ server | sync, archive, retrieve, remote compute | iOS Simulator → server on this Mac | `scripts/test_all.sh --live` |
| Real data | engine on the owner's export | Mac, `~/Desktop/HealthExport/fengshui_health.sqlite` | `scripts/real_data_check.sh` (local-only report) |

`scripts/test_all.sh` runs every layer and prints a pass/fail table (target < 10 min).

## Testability rules

- Every Apple framework dependency is behind a protocol with a real and a fake implementation: HealthKit store, location manager / monitor, motion history, watch sensors (`CMSensorRecorder`, device motion, altimeter, heading), WatchConnectivity, notification center, battery state, clock, network / Anthropic client.
- `-FengshuiTestMode <scenario>` (`new_user`, `typical_week`, `no_watch_data`, `shift_worker`, `sparse_data`) swaps in fakes loaded from `fixtures/scenarios/<scenario>.json`, so UI tests never hit permission dialogs.
- One generator (`engine/tests/synth.py`) writes the scenarios; Python tests and Swift fakes read the same files.
- Fixed clocks and seeded randomness everywhere. Golden outputs live in `fixtures/golden/`.
- A failing test that can't be fixed after a genuine effort is marked expected-failure (`pytest.mark.xfail(strict=True, reason=…)` / `XCTExpectFailure`) and listed in `PROGRESS.md`; tests are never deleted or weakened.

## Owner-provided test data (found 2026-10-24)

Location: `~/Desktop/HealthExport/` — **treated as private** (contains real recordings, a device ID and GPS). Never copied into the repo; used only by local, opt-in tests that skip when the files are absent.

| File | Format | Contents | Date range |
| --- | --- | --- | --- |
| `export.zip` | Apple Health export (`apple_health_export/export.xml`, 1.2 GB, + 21 `workout-routes/*.gpx`, no ECG, no CDA) | the owner's full Health history | to 2026-10-24 (full range in `import_report.md`) |
| `2 min test data-….zip` | Sensor Logger (iOS app v1.67.1) CSV export, one CSV per sensor: `time` (Unix ns), `seconds_elapsed`, values | `WatchAccelerometerUncalibrated` (g, ~100 Hz, includes buffered history before the recording start), `WristMotion` (device motion: rotation rate rad/s, gravity, user acceleration, attitude, ~100 Hz), `WatchBarometer` (relative altitude m, pressure kPa), `WatchCompass` (magnetic bearing °), `WatchMagnetometer` (µT), `HeartRate` (bpm, ~every 5 s), empty `Annotation` | 2026-09-30 15:45 America/New_York |
| `36 min data-….zip` | same, plus `WatchLocation` (GPS lat/lon/alt/speed/accuracy) | ~36 min recording, accelerometer buffer covers ~70 min | 2026-09-30 16:25 America/New_York |

Uses:
- **Raw codec / compression ratio:** encode the real 100 Hz accelerometer (resampled to 50 Hz), barometer, compass and HR into `fsr1` chunks and report the ratio next to the synthetic one.
- **Feature extraction:** run `features` on the converted traces and check cadence / ENMO are in plausible ranges (no golden values from real data are committed).
- **Importer and engine checks:** `export.zip` → Task B importer → real-data check (`engine_check.md`, local only).
- The synthetic generator still covers every case; no test depends only on this data.

## Phase gates

Exactly as in SPEC §14.2. Each phase's gate plus all earlier gates must pass before merging to `main` and tagging `phase-N`.
