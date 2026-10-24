# Progress

## Status

| Phase | State | Gate |
| --- | --- | --- |
| Plan | done | — |
| 0 Foundations | done (tag `phase-0`) | PASS |
| 1 Database + HealthKit | — | — |
| 2 Context | — | — |
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
