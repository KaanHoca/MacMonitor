#!/bin/bash
# MacMonitor — Double-click to build and launch
set -e

cd "$(dirname "$0")"

# Check for Xcode Command Line Tools
if ! xcode-select -p &>/dev/null; then
    echo "Xcode Command Line Tools required. Installing..."
    xcode-select --install
    echo "After installation completes, double-click this file again."
    read -p "Press Enter to close..."
    exit 1
fi

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
  MacMonitor/ContentView.swift \
  MacMonitor/MacMonitorApp.swift

echo "Creating app bundle..."
mkdir -p MacMonitor.app/Contents/MacOS
mkdir -p MacMonitor.app/Contents/Resources
mv MacMonitor_bin MacMonitor.app/Contents/MacOS/MacMonitor
cp MacMonitor/Info.plist MacMonitor.app/Contents/

echo "Launching..."
open MacMonitor.app

echo ""
echo "MacMonitor is ready! You can close this window."
