# Switching to the paid Apple Developer Program

The build is set up so the switch is a configuration change, not a rewrite (spec §1a).

## 1. Back up first

1. On the Mac: `scripts/run_server.sh`.
2. On the iPhone: Settings → Server & compute → **Sync now** (this also archives raw chunks older than 7 days to the Mac).
3. On the iPhone: Settings → Device test → **Export database** → save `fengshui-<date>.sqlite` to Files / AirDrop it to the Mac.
4. Keep the server's `server/data/` folder; it holds the archived raw blobs.

## 2. Change the team

1. Join the program, then in Xcode → Settings → Accounts select the paid team and note its Team ID.
2. Edit `apple/Config/Local.xcconfig`:
   ```
   DEVELOPMENT_TEAM = <paid team id>
   ```
3. Regenerate: `cd apple && ../.tools/xcodegen/bin/xcodegen generate`.

## 3. Reinstall

A different signing team may not be able to install over the existing app, or to register the same bundle IDs (`com.chevin.fengshui`, `com.chevin.fengshui.watchkitapp`). If Xcode refuses:

1. Delete Fengshui from the iPhone and the Watch.
2. `scripts/install_on_devices.sh`.
3. Restore: put the exported `.sqlite` into the app's container (Xcode → Window → Devices and Simulators → Fengshui → Download/Replace Container), or start fresh and let the HealthKit backfill re-read everything. HealthKit data itself is safe in Apple Health. Raw watch chunks older than 7 days are on the Mac (`GET /raw`).

## 4. Turn on paid-only features

1. In `apple/Config/Local.xcconfig` add `FENGSHUI_PAID_ACCOUNT = YES` (compiles the Screen Time code paths and onboarding step).
2. Add the **Family Controls** capability (Individual) to the `Fengshui` target in `project.yml` (`com.apple.developer.family-controls: true`).
3. Add the `ScreenTimeMonitor` extension target (`com.chevin.fengshui.ScreenTimeMonitor`, DeviceActivityMonitor) with the App Group `group.com.chevin.fengshui`.
4. Optional: move the complication from ClockKit to a WidgetKit extension (DECISIONS D-07), and request the time-sensitive notifications entitlement.

## 5. Spike B: can the DeviceActivity extension write to the App Group?

There are reports that DeviceActivity extensions can't write to shared containers (spec §6.4). Before building the full feature:

1. In the extension's `eventDidReachThreshold`, append `{ts, schedule, threshold}` as one JSON line to `<App Group>/screen_events.jsonl`.
2. Schedule a 1-minute test threshold, use the phone, and check whether the line appears (Settings → Debug shows the file's line count).
3. **If writing works:** import the lines into `context_screen_events` on each sync (UNIQUE(ts, schedule, threshold_min) makes it idempotent), then do the Screen Time part of Phase 2 (schedules `daily` 00:00–23:59 at 30, 60 … 480 min; `evening` 21:00–23:59 at 15, 30, 60 min) and its tests.
4. **If writing is blocked:** show Screen Time as unavailable in the UI and continue without it. The engine and Claude tools already handle an empty table.
