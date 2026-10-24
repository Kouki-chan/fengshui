#!/bin/bash
# One-time (idempotent) setup of everything the build needs, without installing
# anything system-wide (DECISIONS D-01). Tools go to .tools/, Python deps to .venv/.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TOOLS="$ROOT/.tools"
mkdir -p "$TOOLS/dl"

PY_STANDALONE="https://github.com/astral-sh/python-build-standalone/releases/download/20261021/cpython-3.13.17%2B20261021-aarch64-apple-darwin-install_only.tar.gz"
XCODEGEN="https://github.com/yonaskolb/XcodeGen/releases/download/2.46.0/xcodegen.zip"
PY_IOS="https://github.com/beeware/Python-Apple-support/releases/download/3.13-b16/Python-3.13-iOS-support.b16.tar.gz"

if [ ! -x "$TOOLS/python/bin/python3.13" ]; then
  echo "• Python 3.13 (repo-local)"
  curl -fsSL -o "$TOOLS/dl/py.tgz" "$PY_STANDALONE"
  tar xzf "$TOOLS/dl/py.tgz" -C "$TOOLS"
fi

if [ ! -x "$TOOLS/xcodegen/bin/xcodegen" ]; then
  echo "• XcodeGen (repo-local)"
  curl -fsSL -o "$TOOLS/dl/xcodegen.zip" "$XCODEGEN"
  unzip -qo "$TOOLS/dl/xcodegen.zip" -d "$TOOLS"
fi

if [ ! -d "$ROOT/apple/Python/Python.xcframework" ]; then
  echo "• Python-Apple-support 3.13-b16 → apple/Python"
  curl -fsSL -o "$TOOLS/dl/pyios.tgz" "$PY_IOS"
  mkdir -p "$ROOT/apple/Python"
  tar xzf "$TOOLS/dl/pyios.tgz" -C "$ROOT/apple/Python" Python.xcframework VERSIONS
fi

if [ ! -x "$ROOT/.venv/bin/python" ]; then
  echo "• venv"
  "$TOOLS/python/bin/python3.13" -m venv "$ROOT/.venv"
fi
"$ROOT/.venv/bin/pip" install -q --upgrade pip
"$ROOT/.venv/bin/pip" install -q pytest fastapi "uvicorn[standard]" httpx tzdata zeroconf
"$ROOT/.venv/bin/pip" install -q -e "$ROOT/engine"
[ -f "$ROOT/server/pyproject.toml" ] && "$ROOT/.venv/bin/pip" install -q -e "$ROOT/server"

# Secret check runs before every commit.
printf '#!/bin/bash\nexec "$(git rev-parse --show-toplevel)/scripts/check_secrets.sh"\n' > "$ROOT/.git/hooks/pre-commit"
chmod +x "$ROOT/.git/hooks/pre-commit"

# Simulator builds work without a team; device builds read DEVELOPMENT_TEAM from here.
if [ ! -f "$ROOT/apple/Config/Local.xcconfig" ]; then
  printf '// Local, gitignored. Set your Personal Team ID for device builds.\nDEVELOPMENT_TEAM =\n' \
    > "$ROOT/apple/Config/Local.xcconfig"
fi

echo "• Generating Xcode project"
(cd "$ROOT/apple" && "$TOOLS/xcodegen/bin/xcodegen" generate --quiet)
echo "bootstrap: OK"
