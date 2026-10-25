#!/bin/bash
# Live phone ↔ server integration (spec §14.2 Phase 6): starts the server on this Mac with a
# throwaway data dir + token, runs LiveServerTests in the simulator against it, stops it.
# Usage: scripts/live_server_test.sh [simulator-udid]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="${1:-}"
PORT=$((20000 + RANDOM % 20000))
TMP=$(mktemp -d)
TOKEN=$("$ROOT/.venv/bin/python" -c "import secrets; print(secrets.token_urlsafe(24))")
[ -f "$ROOT/build/parity/source.sqlite" ] || "$ROOT/.venv/bin/python" "$ROOT/engine/tests/parity.py"
(cd "$ROOT/server" && FENGSHUI_TOKEN="$TOKEN" FENGSHUI_DATA_DIR="$TMP/data" \
  "$ROOT/.venv/bin/python" -m fengshui_server --host 127.0.0.1 --port "$PORT" --no-bonjour > "$TMP/server.log" 2>&1) &
PID=$!
trap 'kill $PID 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$PORT/health" > /dev/null && break; sleep 0.2; done
[ -z "$SIM" ] && SIM=$(xcrun simctl list devices available | grep -m1 "iPhone 17 Pro (" | grep -oE '[0-9A-F-]{36}')
TEST_RUNNER_FENGSHUI_LIVE_URL="http://127.0.0.1:$PORT" TEST_RUNNER_FENGSHUI_LIVE_TOKEN="$TOKEN" \
  xcodebuild test -project "$ROOT/apple/Fengshui.xcodeproj" -scheme FengshuiUnit \
  -only-testing:FengshuiTests/LiveServerTests -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath "$ROOT/build/dd"
RC=$?
echo "--- server log (tail)"; tail -5 "$TMP/server.log"
exit $RC
