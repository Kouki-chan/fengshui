#!/bin/bash
# Live Claude smoke test (spec §14.2 Phase 7): runs only if ANTHROPIC_API_KEY is set in the
# environment. The key is passed to the simulator test process, never written to a file or printed.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
if [ -z "${ANTHROPIC_API_KEY:-}" ]; then echo "ANTHROPIC_API_KEY not set: skipping live Claude smoke test"; exit 0; fi
SIM="${1:-$(xcrun simctl list devices available | grep -m1 'iPhone 17 Pro (' | grep -oE '[0-9A-F-]{36}')}"
[ -f "$ROOT/build/parity/mac.sqlite" ] || "$ROOT/.venv/bin/python" "$ROOT/engine/tests/parity.py"
TEST_RUNNER_FENGSHUI_ANTHROPIC_KEY="$ANTHROPIC_API_KEY" xcodebuild test -project "$ROOT/apple/Fengshui.xcodeproj" \
  -scheme FengshuiUnit -only-testing:FengshuiTests/LiveClaudeTests -destination "platform=iOS Simulator,id=$SIM" \
  -derivedDataPath "$ROOT/build/dd" 2>&1 | grep -E "METRIC|Test Case|TEST (SUCCEEDED|FAILED)|error:"
