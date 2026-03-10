#!/bin/bash
# MacMonitor — Derle ve çalıştır
set -e

cd "$(dirname "$0")"

SDK=$(xcrun --show-sdk-path)
ARCH=$(uname -m)

echo "⚙ Derleniyor..."
swiftc \
  -target ${ARCH}-apple-macosx13.0 \
  -sdk "$SDK" \
  -framework AppKit \
  -framework SwiftUI \
  -framework IOKit \
  -parse-as-library \
  -O \
  -o MacMonitor_bin \
  MacMonitor/SystemMonitor.swift \
  MacMonitor/ContentView.swift \
  MacMonitor/MacMonitorApp.swift

echo "📦 .app bundle oluşturuluyor..."
mkdir -p MacMonitor.app/Contents/MacOS
mkdir -p MacMonitor.app/Contents/Resources
mv MacMonitor_bin MacMonitor.app/Contents/MacOS/MacMonitor
cp MacMonitor/Info.plist MacMonitor.app/Contents/

echo "✅ MacMonitor.app hazır!"
echo ""
echo "Çalıştırmak için:"
echo "  open MacMonitor.app"
echo ""
echo "Applications klasörüne kopyalamak için:"
echo "  cp -r MacMonitor.app /Applications/"
