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
The Health export has no UUIDs, so imported rows use `hk_uuid = "export:" + sha1(hk_type|start|end|source_name|value|value_text)`. When the app's HealthKit sync later sees a sample, it computes the same tuple key first. If a non-deleted `export:` row with that key exists, it **updates that row's `hk_uuid` to the real UUID** (keeping `id`) instead of inserting. Timestamps are compared after rounding to whole seconds, because the export has 1 s resolution. Implemented in `FengshuiKit.ExportKey` and `fengshui_engine.importer.export_key`, which share test vectors.

## D-07 — Complication via ClockKit inside the watch app
WidgetKit complications need a widget extension with its own bundle ID, a third App ID. That breaks "exactly two App IDs" on a free account. ClockKit (deprecated, still in the watchOS 27 SDK) lets the watch app itself be the complication data source. Revisit with the paid account (move to WidgetKit).

## D-08 — No `location` background mode
Visit monitoring, significant-location-change and `CLMonitor` events relaunch a terminated app in the background without the `location` UIBackgroundMode (which is only for continuous updates). The spec allows the mode "only if visit monitoring requires it", and it doesn't.

## D-09 — Simulator runtimes
Installed: iOS 27.0, watchOS 27.0. iOS 26.0 is being added for the spec's iOS 26 tests. The oldest watchOS runtime Xcode 27 offers is used for watchOS tests; whatever is used gets recorded in PROGRESS.md.
