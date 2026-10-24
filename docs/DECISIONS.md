# Decisions

Each entry: what the spec says, what was done, why.

## D-01 — Repo-local toolchain instead of Homebrew
Homebrew is not installed on this Mac (checked 2026-10-24). Python 3.13.17 (python-build-standalone 20261021) and XcodeGen 2.46.0 are unpacked into `.tools/` (gitignored); `scripts/bootstrap.sh` recreates them. Nothing is installed system-wide.

## D-02 — GitHub deferred
Owner asked to ignore GitHub setup for now. Work is committed locally with the same branch/merge/tag discipline; `scripts/check_secrets.sh` runs as a pre-commit hook. Pushing (and checking that the repo is private) happens when `gh` is authenticated.

## D-03 — Embedded Python: BeeWare Python-Apple-support 3.13-b16
Chosen over Briefcase because only the XCFramework + stdlib is needed, without Briefcase's project templates. b16 (2026-10-06) over b17 (2026-10-22): the newer build was only two days old.

## D-04 — Single schema source
`engine/fengshui_engine/schema_v1.sql` is the only copy of schema v1. FengshuiKit bundles it as a resource and the GRDB migrator executes it, so the Swift and Python schemas can't drift.

## D-05 — No NumPy
The engine stays pure Python (spec §8 makes NumPy optional). This avoids building NumPy for iOS and needing a backend switch.

## D-06 — Export UUIDs vs. later HealthKit UUIDs
The Health export has no UUIDs, so imported rows use `hk_uuid = "export:" + sha1(hk_type|start|end|source_name|value|value_text)`. The key makes re-imports idempotent. Timestamps in the key are whole seconds (floor(x + 0.5) on both sides), because the export has 1 s resolution. `FengshuiKit.ExportKey` and `fengshui_engine.export_key` compute the same key.

**Avoiding duplicates when real HealthKit samples arrive** (phone sync, or the server merging a phone sync into a DB that holds an import). The exact hash can't be used: the export writes category values as names (`HKCategoryValueSeverityMild`) where HealthKit has raw ints, and workout durations as rounded minutes. So adoption matches on **the same tuple with tolerances**. Before inserting a sample whose real UUID is unknown, look for a non-deleted `export:` row with the same `label` and `source_name`, `start_ts` and `end_ts` each within ±1 s, the same `value_text` when both have one, and `value` within 0.1 % (or 0.01 absolute) when both have one. Workouts compare only times, source and activity type. If exactly one row matches, it **adopts the real UUID** (its `hk_uuid` is updated, `id` kept) and gets HealthKit's fields. Otherwise the sample is inserted. The check only runs when the label has any `export:` rows (cached per label), so normal syncs pay nothing. Implemented as `ExportAdoption` (Swift) and `fengshui_engine.export_key.find_export_match` (Python, used by the server), with shared tests. Any duplicates that remain are counted by the real-data check and the device test (`export:` rows that were never adopted).

## D-07 — Complication via ClockKit inside the watch app
WidgetKit complications need a widget extension with its own bundle ID, a third App ID. That breaks "exactly two App IDs" on a free account. ClockKit (deprecated, still in the watchOS 27 SDK) lets the watch app itself be the complication data source. Revisit with the paid account (move to WidgetKit).

## D-08 — No `location` background mode
Visit monitoring, significant-location-change and `CLMonitor` events relaunch a terminated app in the background without the `location` UIBackgroundMode (which is only for continuous updates). The spec allows the mode "only if visit monitoring requires it", and it doesn't.

## D-10 — HealthKit type list
`scripts/gen_hk_catalog.py` reads the Xcode 27 SDK headers and keeps every object type with `ios(≤ 26.0)` availability: 120 quantity, 68 category, 6 characteristic, 2 correlation, 2 scored-assessment (GAD-7, PHQ-9), workout, workout route, heartbeat series, state of mind, audiogram, ECG = 204. It writes `HealthTypeCatalog+Generated.swift` and `fixtures/hk_identifiers_ios26.json`. Swift can't enumerate HealthKit identifiers at runtime; at launch the app logs which catalog entries resolve to an `HKObjectType` on the device. Excluded: clinical records (CDA document, needs the health-records entitlement), `AudioExposureEvent` (deprecated), medications and vision prescriptions (need per-object authorization, a separate sheet per object). Four types are newer than iOS 26 and skipped (RMSSD HRV, hypertension event, menopause types). Background delivery is requested for the six spec types only.

## D-11 — Watch uses no location; compass from the magnetometer
Owner's instruction (2026-10-24): the watch must not need location data; location comes from the iPhone. The watch asks for no location permission, and its Info.plist has no location usage strings. The compass "sensor" (tier 2 snapshots and tier 3 sessions) is a **tilt-compensated heading computed on the watch** from the raw magnetometer (`CMMotionManager.startMagnetometerUpdates`) and device-motion gravity (`FengshuiKit.Compass`, unit-tested). That replaces `CLLocationManager` heading, which needs location authorization and may not deliver in the background. The magnetometer is uncalibrated, so the absolute heading can carry a fixed offset. The engine only uses heading changes (`heading_change_deg`), which the offset doesn't affect. All place and visit context (`context_visits`, geofences, suggestions) comes from the iPhone's Core Location (spec §6.2). Device test: confirm `isMagnetometerAvailable` on the Watch SE (1st gen) and that compass chunks arrive.

## D-09 — Simulator runtimes
Installed: iOS 27.0, watchOS 27.0. iOS 26.0 is being added for the spec's iOS 26 tests. The oldest watchOS runtime Xcode 27 offers is used for watchOS tests; whatever is used gets recorded in PROGRESS.md.
