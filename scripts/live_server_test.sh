#!/bin/bash
# Live phone ↔ server integration (spec §14.2 Phase 6): starts the server on this Mac with a
# throwaway data dir + token, runs LiveServerTests in the simulator against it, stops it.
# Usage: scripts/live_server_test.sh [simulator-udid]
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SIM="${1:-}"
# One fixed port, next to the real server's 8765 so the two never collide.
PORT=8766
# A test server left over from an interrupted run: stop it (only our own test server, never the real one).
for pid in $(lsof -ti tcp:$PORT -sTCP:LISTEN 2>/dev/null); do
  ps -o command= -p "$pid" | grep -q "fengshui_server --host 127.0.0.1 --port $PORT" && kill "$pid"
done
TMP=$(mktemp -d)
TOKEN=$("$ROOT/.venv/bin/python" -c "import secrets; print(secrets.token_urlsafe(24))")
[ -f "$ROOT/build/parity/source.sqlite" ] || "$ROOT/.venv/bin/python" "$ROOT/engine/tests/parity.py"
(cd "$ROOT/server" && FENGSHUI_TOKEN="$TOKEN" FENGSHUI_DATA_DIR="$TMP/data" \
  exec "$ROOT/.venv/bin/python" -m fengshui_server --host 127.0.0.1 --port "$PORT" --no-bonjour > "$TMP/server.log" 2>&1) &
PID=$!
# exec above makes $PID the server itself, so this stops it (killing a wrapper subshell didn't).
trap 'kill $PID 2>/dev/null; wait $PID 2>/dev/null; rm -rf "$TMP"' EXIT
for _ in $(seq 1 50); do curl -s "http://127.0.0.1:$PORT/health" > /dev/null && break; sleep 0.2; done
[ -z "$SIM" ] && SIM=$(xcrun simctl list devices available | grep -m1 "iPhone 17 Pro (" | grep -oE '[0-9A-F-]{36}')
TEST_RUNNER_FENGSHUI_LIVE_URL="http://127.0.0.1:$PORT" TEST_RUNNER_FENGSHUI_LIVE_TOKEN="$TOKEN" \
  xcodebuild test -project "$ROOT/apple/Fengshui.xcodeproj" -scheme FengshuiUnit \
  -only-testing:FengshuiTests/LiveServerTests -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath "$ROOT/build/dd"
RC=$?
echo "--- server log (tail)"; tail -5 "$TMP/server.log"
exit $RC
