#!/bin/bash
# Builds Fengshui (iPhone + embedded Watch app) and installs it on a connected, unlocked iPhone
# with Developer Mode on. The watch app installs through the iPhone (Watch app → Available Apps)
# or automatically when "Automatic App Install" is on.
#   scripts/install_on_devices.sh            # first connected iPhone
#   scripts/install_on_devices.sh <udid>
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CFG="$ROOT/apple/Config/Local.xcconfig"
if ! grep -qE '^DEVELOPMENT_TEAM *= *[A-Z0-9]{10}' "$CFG" 2>/dev/null; then
  echo "Set your Team ID first: apple/Config/Local.xcconfig → DEVELOPMENT_TEAM = XXXXXXXXXX"
  echo "(Xcode → Settings → Accounts → your Apple Account → Personal Team)"
  exit 1
fi
UDID="${1:-$(xcrun devicectl list devices 2>/dev/null | awk '/iPhone/ && !/simulated/ && /connected|available/ {for (i=1;i<=NF;i++) if ($i ~ /^[0-9A-F-]{25,}$/) {print $i; exit}}')}"
if [ -z "$UDID" ]; then
  echo "No connected iPhone found. Connect it with a cable, unlock it, trust this Mac, and turn on Developer Mode."
  xcrun devicectl list devices || true
  exit 1
fi
echo "• Building for device $UDID"
(cd "$ROOT/apple" && "$ROOT/.tools/xcodegen/bin/xcodegen" generate --quiet)
xcodebuild build -project "$ROOT/apple/Fengshui.xcodeproj" -scheme Fengshui -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$ROOT/build/dd-install" -allowProvisioningUpdates \
  | grep -E "error:|warning: .*provision|BUILD (SUCCEEDED|FAILED)" || true
APP="$ROOT/build/dd-install/Build/Products/Debug-iphoneos/Fengshui.app"
[ -d "$APP" ] || { echo "Build failed; open apple/Fengshui.xcodeproj in Xcode to see signing details."; exit 1; }
echo "• Installing"
xcrun devicectl device install app --device "$UDID" "$APP"
echo "• Done. On the iPhone: Settings → General → VPN & Device Management → trust your developer certificate if asked."
echo "  Watch app: iPhone Watch app → My Watch → Available Apps → Fengshui → Install."
