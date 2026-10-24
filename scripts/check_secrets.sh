#!/bin/bash
# Refuses to let private files or secrets into git. Run as a pre-commit hook
# (scripts/bootstrap.sh installs it) and before every push.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

fail=0
staged=$(git diff --cached --name-only --diff-filter=ACMR)

# 1. Forbidden file names.
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    *.sqlite|*.sqlite-*|*.db|*.db-*|*.zip|*export.xml|*export_cda.xml|.env|.env.*|*/.env|*Local.xcconfig)
      echo "BLOCKED: private file staged: $f"; fail=1 ;;
  esac
done <<< "$staged"

# 2. Secret-looking content in staged diffs (added lines only).
diff=$(git diff --cached -U0 | grep '^+' | grep -v '^+++' || true)
if grep -Eq 'sk-ant-[A-Za-z0-9_-]{10,}' <<< "$diff"; then
  echo "BLOCKED: Anthropic API key pattern found"; fail=1
fi
if grep -Eiq 'Bearer [A-Za-z0-9._-]{20,}' <<< "$diff"; then
  echo "BLOCKED: bearer token found"; fail=1
fi

# 3. The real Team ID, if known locally (it lives only in the gitignored xcconfig).
local_cfg="apple/Config/Local.xcconfig"
if [ -f "$local_cfg" ]; then
  team=$(sed -n 's/^DEVELOPMENT_TEAM *= *\([A-Z0-9]*\).*/\1/p' "$local_cfg" | head -1)
  if [ -n "${team:-}" ] && grep -q "$team" <<< "$diff"; then
    echo "BLOCKED: Team ID found in staged changes"; fail=1
  fi
fi

[ $fail -eq 0 ] && echo "check_secrets: OK"
exit $fail
