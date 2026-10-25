#!/bin/bash
# Runs every automated test layer and prints a pass/fail table (spec §14.1).
#   scripts/test_all.sh            all layers
#   scripts/test_all.sh --quick    skip UI tests
#   scripts/test_all.sh --no-live  skip the live phone↔server integration test
# Logs: build/test-logs/<layer>.log
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOGS="$ROOT/build/test-logs"
DD="$ROOT/build/dd"
mkdir -p "$LOGS"
QUICK=0; LIVE=1
for a in "$@"; do
  case "$a" in --quick) QUICK=1 ;; --live) LIVE=1 ;; esac
done

# Simulators: iPhone 17 Pro on the oldest installed iOS ≥ 26, Apple Watch SE on the oldest watchOS.
sim_id() { # $1 = runtime prefix (iOS / watchOS), $2 = device name
  xcrun simctl list devices available -j | "$ROOT/.venv/bin/python" -c "
import json, sys
d = json.load(sys.stdin)['devices']
rts = sorted((k for k in d if '.$1-' in k), key=lambda k: [int(x) for x in k.split('$1-')[1].split('-')])
for rt in rts:
    for dev in d[rt]:
        if dev['name'].startswith('$2'):
            print(dev['udid']); sys.exit()
"
}
IPHONE=$(sim_id iOS "iPhone 17 Pro")
WATCH=$(sim_id watchOS "Apple Watch SE")

# Tests copy scenario databases into the simulator's tmp folders; clear them so they don't pile up.
find "$HOME/Library/Developer/CoreSimulator/Devices/$IPHONE/data/Containers/Data/Application" -path "*/tmp/*" \
  \( -name "*.sqlite" -o -name "*.sqlite-wal" -o -name "*.sqlite-shm" \) -delete 2>/dev/null

names=(); results=(); times=()
run_layer() { # name, command...
  local name="$1"; shift
  local t0=$SECONDS
  echo "▶ $name"
  if "$@" > "$LOGS/$name.log" 2>&1; then results+=("PASS"); else results+=("FAIL"); fi
  names+=("$name"); times+=("$((SECONDS - t0))s")
}

run_layer python-engine   "$ROOT/.venv/bin/pytest" -q "$ROOT/engine/tests"
[ -d "$ROOT/scripts/tests" ] && run_layer python-importer "$ROOT/.venv/bin/pytest" -q "$ROOT/scripts/tests"
[ -d "$ROOT/server/tests" ] && run_layer python-server "$ROOT/.venv/bin/pytest" -q "$ROOT/server/tests"
# Phone/Mac engine parity: the Mac result the simulator test compares against.
run_layer parity-prep     "$ROOT/.venv/bin/python" "$ROOT/engine/tests/parity.py"
run_layer swift-kit       swift test --package-path "$ROOT/apple/FengshuiKit"
run_layer xcodegen        bash -c "cd '$ROOT/apple' && '$ROOT/.tools/xcodegen/bin/xcodegen' generate --quiet"
# Grants notification permission on the simulator (once; persists) for the real-center test.
run_layer ios-notif-perm  xcodebuild test -project "$ROOT/apple/Fengshui.xcodeproj" -scheme Fengshui \
                            -only-testing:FengshuiUITests/NotificationPermissionUITests \
                            -destination "platform=iOS Simulator,id=$IPHONE" -derivedDataPath "$DD"
run_layer ios-unit        xcodebuild test -project "$ROOT/apple/Fengshui.xcodeproj" -scheme FengshuiUnit \
                            -destination "platform=iOS Simulator,id=$IPHONE" -derivedDataPath "$DD"
# The iOS tests write build/swift_created.sqlite; the engine must accept it.
run_layer python-swiftdb  env FENGSHUI_REQUIRE_SWIFT_DB=1 "$ROOT/.venv/bin/pytest" -q "$ROOT/engine/tests/test_swift_db.py"
run_layer watch-unit     xcodebuild test -project "$ROOT/apple/Fengshui.xcodeproj" -scheme FengshuiWatch \
                            -destination "platform=watchOS Simulator,id=$WATCH" -derivedDataPath "$DD"
if [ $QUICK -eq 0 ]; then
  run_layer ios-ui        xcodebuild test -project "$ROOT/apple/Fengshui.xcodeproj" -scheme Fengshui \
                            -only-testing:FengshuiUITests/LaunchUITests -only-testing:FengshuiUITests/OnboardingUITests \
                            -destination "platform=iOS Simulator,id=$IPHONE" \
                            -derivedDataPath "$DD"
fi
if [ $LIVE -eq 1 ] && [ -x "$ROOT/scripts/live_server_test.sh" ]; then
  run_layer live-server   "$ROOT/scripts/live_server_test.sh" "$IPHONE"
fi
if [ -n "${ANTHROPIC_API_KEY:-}" ]; then
  run_layer claude-live   "$ROOT/scripts/claude_smoke_test.sh" "$IPHONE"
fi

echo
printf "%-18s %-6s %s\n" LAYER RESULT TIME
fail=0
for i in "${!names[@]}"; do
  printf "%-18s %-6s %s\n" "${names[$i]}" "${results[$i]}" "${times[$i]}"
  [ "${results[$i]}" = FAIL ] && fail=1
done
# Expected failures are reported by each layer's own summary (xfail / XCTExpectFailure).
grep -h -E "xfailed|expected failure" "$LOGS"/*.log 2>/dev/null | sort -u | sed 's/^/  note: /'
echo "simulators: iPhone=$IPHONE watch=$WATCH  total ${SECONDS}s"
exit $fail
