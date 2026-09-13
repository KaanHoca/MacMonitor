#!/bin/bash
# MacMonitor: regenerate the app icon from design/MacMonitor-logo.png.
# Needs Xcode 26 (actool with Icon Composer support). The generated files are
# committed, so building the app itself never needs Xcode.
set -e

cd "$(dirname "$0")"

if ! xcrun --find actool >/dev/null 2>&1; then
    echo "actool not found. Install Xcode 26 and select it with xcode-select." >&2
    exit 1
fi

OUT=../MacMonitor/Resources
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# The PNG is the source of truth; MacMonitor.icon wraps it for Icon Composer.
cp MacMonitor-logo.png MacMonitor.icon/Assets/MacMonitor-logo.png

# Produces Assets.car (macOS 26 icon plus renditions for older systems) and
# MacMonitor.icns (legacy fallback) for a macOS 13.0 deployment target.
xcrun actool MacMonitor.icon \
  --compile "$TMP" \
  --output-format human-readable-text --notices --warnings --errors \
  --output-partial-info-plist "$TMP/partial.plist" \
  --app-icon MacMonitor --include-all-app-icons \
  --enable-on-demand-resources NO \
  --development-region en \
  --target-device mac \
  --minimum-deployment-target 13.0 \
  --platform macosx

mkdir -p "$OUT"
cp "$TMP/Assets.car" "$TMP/MacMonitor.icns" "$OUT/"
echo "Updated $OUT/Assets.car and $OUT/MacMonitor.icns"
