#!/bin/bash
# Starts the Fengshui server on this Mac (spec §12). First run generates a bearer token
# into server/.env (gitignored) and prints it once so you can enter it in the iPhone
# app (Settings → Server). Usage: scripts/run_server.sh [--port 8765] [--no-bonjour]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENV="$ROOT/server/.env"
if [ ! -f "$ENV" ]; then
  TOKEN=$("$ROOT/.venv/bin/python" -c "import secrets; print(secrets.token_urlsafe(32))")
  umask 077
  printf 'FENGSHUI_TOKEN=%s\nFENGSHUI_DATA_DIR=%s\n' "$TOKEN" "$ROOT/server/data" > "$ENV"
  echo "Generated a new server token (saved in server/.env). Enter it in the iPhone app: Settings → Server."
  echo "  token: $TOKEN"
fi
cd "$ROOT/server"
exec "$ROOT/.venv/bin/python" -m fengshui_server "$@"
