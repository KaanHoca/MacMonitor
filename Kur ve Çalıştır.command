#!/bin/bash
# MacMonitor — Çift tıkla, kurulsun ve açılsın
set -e

cd "$(dirname "$0")"

# Xcode Command Line Tools kontrolü
if ! xcode-select -p &>/dev/null; then
    echo "Xcode Command Line Tools gerekli. Kuruluyor..."
    xcode-select --install
    echo "Kurulum tamamlandıktan sonra bu dosyayı tekrar çift tıkla."
    read -p "Kapatmak için Enter'a bas..."
    exit 1
fi

SDK=$(xcrun --show-sdk-path)
ARCH=$(uname -m)

echo "Derleniyor..."
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

echo "Uygulama oluşturuluyor..."
mkdir -p MacMonitor.app/Contents/MacOS
mkdir -p MacMonitor.app/Contents/Resources
mv MacMonitor_bin MacMonitor.app/Contents/MacOS/MacMonitor
cp MacMonitor/Info.plist MacMonitor.app/Contents/

echo "Başlatılıyor..."
open MacMonitor.app

echo ""
echo "MacMonitor hazır! Bu pencereyi kapatabilirsin."
