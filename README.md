# Fengshui

A personal proof-of-concept iPhone + Apple Watch app with an embedded Python inference engine and a server that runs on your Mac. It reads your Health data, iPhone motion and visits to your places, plus passive watch sensors. From those it detects activity, plans your evening wind-down (with a reminder at the right time), and lets Claude answer questions about your own data, using processed data only, never raw watch data.

Spec: [`docs/SPEC.md`](docs/SPEC.md) · Plan: [`docs/PLAN.md`](docs/PLAN.md) · Status: [`docs/PROGRESS.md`](docs/PROGRESS.md) · Decisions: [`docs/DECISIONS.md`](docs/DECISIONS.md) · Algorithms: [`docs/ALGORITHMS.md`](docs/ALGORITHMS.md) · Tests: [`docs/TEST_STRATEGY.md`](docs/TEST_STRATEGY.md) · Final report: [`docs/FINAL_REPORT.md`](docs/FINAL_REPORT.md) · **Device test: [`docs/DEVICE_TEST_CHECKLIST.md`](docs/DEVICE_TEST_CHECKLIST.md)**

## Layout

| Path | What |
| --- | --- |
| `apple/project.yml` | XcodeGen spec (the `.xcodeproj` is generated, never edited) |
| `apple/FengshuiKit/` | Swift package shared by iPhone + Watch: `minute_id`, raw codec, watch pipeline, preferences |
| `apple/Fengshui/` | iPhone app (HealthKit, places, motion, watch import, embedded engine, notifications, server sync, Claude, UI) |
| `apple/FengshuiWatch/` | Watch app (sensor tiers, sessions, WatchConnectivity, complication) |
| `engine/fengshui_engine/` | Pure-Python engine (features, activity, wind-down, place suggestions); runs on the phone and the Mac |
| `server/fengshui_server/` | FastAPI server for the Mac (sync, raw archive, remote compute, diagnostics) |
| `scripts/` | bootstrap, tests, server, importer, device install, checks |
| `fixtures/` | synthetic test data only |


Nothing is installed system-wide. Device builds need your Team ID in `apple/Config/Local.xcconfig` (gitignored):

```
DEVELOPMENT_TEAM = ABCDE12345
```

Find it in Xcode → Settings → Accounts → your Apple Account → Personal Team.

## Everyday commands

| Task | Command |
| --- | --- |
| Run every test layer | `scripts/test_all.sh` (about 4 min; `--quick` skips UI tests, `--no-live` skips the live server test) |
| Start the Mac server | `scripts/run_server.sh` (first run prints the token to enter in the app: Settings → Server & compute) |
| Start the server at login | see `scripts/com.chevin.fengshui.server.plist` |
| Install on iPhone + Watch | `scripts/install_on_devices.sh` |
| Import a Health export | put it at `~/Desktop/HealthExport/export.zip`, then `.venv/bin/python scripts/import_health_export.py [--csv]` |
| Run the engine on that export | `.venv/bin/python scripts/real_data_check.py` → `~/Desktop/HealthExport/engine_check.md` (local only) |
| Calibrate activity thresholds | `.venv/bin/python engine/tools/calibrate.py DB --days 60 --source '%Watch%'` |
| Live Claude smoke test | `export ANTHROPIC_API_KEY=…` in your shell, then `scripts/claude_smoke_test.sh` |
| Regenerate the HealthKit catalog (after an Xcode update) | `.venv/bin/python scripts/gen_hk_catalog.py` |
| Regenerate synthetic scenarios | `.venv/bin/python engine/tests/synth.py` |


## Privacy

- Your Health data stays on the iPhone and your own Mac. The repository holds only synthetic data. A pre-commit hook (`scripts/check_secrets.sh`) blocks databases, exports, `.env`, `Local.xcconfig`, API keys, bearer tokens and the Team ID.
- Claude gets only what its read-only tools return: processed samples and inferences, visits by place name without coordinates. Raw watch tables can't be queried, which is enforced and tested.
- The server token and the Anthropic key live only in the iPhone Keychain (and `server/.env` on the Mac).
- The watch never uses location. Its compass is computed from the magnetometer (D-11).
