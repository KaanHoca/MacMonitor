#!/bin/bash
# MacMonitor — Build and run
set -e

cd "$(dirname "$0")"

SDK=$(xcrun --show-sdk-path)
ARCH=$(uname -m)

echo "Compiling..."
swiftc \
  -target ${ARCH}-apple-macosx13.0 \
  -sdk "$SDK" \
  -framework AppKit \
  -framework SwiftUI \
  -framework IOKit \
  -framework ServiceManagement \
  -parse-as-library \
  -O \
  -o MacMonitor_bin \
  MacMonitor/SystemMonitor.swift \
  MacMonitor/DiskCleaner.swift \
  MacMonitor/Components.swift \
  MacMonitor/ContentView.swift \
  MacMonitor/MacMonitorApp.swift

echo "Compiling FanHelper..."
swiftc \
  -target ${ARCH}-apple-macosx13.0 \
  -sdk "$SDK" \
  -framework IOKit \
  -O \
  -o FanHelper_bin \
  MacMonitor/FanHelper.swift

echo "Creating app bundle..."
mkdir -p MacMonitor.app/Contents/MacOS
mkdir -p MacMonitor.app/Contents/Resources
mv MacMonitor_bin MacMonitor.app/Contents/MacOS/MacMonitor
mv FanHelper_bin MacMonitor.app/Contents/MacOS/FanHelper
cp MacMonitor/Info.plist MacMonitor.app/Contents/

echo "MacMonitor.app is ready!"
echo ""
echo "To launch:"
echo "  open MacMonitor.app"
echo ""
echo "To copy to Applications:"
echo "  cp -r MacMonitor.app /Applications/"
