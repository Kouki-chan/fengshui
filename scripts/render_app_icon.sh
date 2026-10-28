#!/bin/bash
# Renders the HealthBot app icons (iPhone light/dark/tinted + watch) into the asset catalogs.
# The artwork is the SwiftUI view in apple/Fengshui/UI/Design/HealthBotLogo.swift.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
xcrun swiftc -O -parse-as-library -o "$TMP/render" \
  "$ROOT/scripts/render_app_icon.swift" "$ROOT/apple/Fengshui/UI/Design/HealthBotLogo.swift"
"$TMP/render" "$TMP"
PHONE="$ROOT/apple/Fengshui/Assets.xcassets/AppIcon.appiconset"
WATCH="$ROOT/apple/FengshuiWatch/Assets.xcassets/AppIcon.appiconset"
mkdir -p "$PHONE" "$WATCH"
cp "$TMP/AppIcon.png" "$TMP/AppIcon-dark.png" "$TMP/AppIcon-tinted.png" "$PHONE/"
cp "$TMP/WatchIcon.png" "$WATCH/AppIcon.png"
echo "Icons written to $PHONE and $WATCH"
