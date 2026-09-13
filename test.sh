#!/bin/bash
# MacMonitor: build and run the geometry unit tests (plain swiftc, no Xcode project)
set -e

cd "$(dirname "$0")"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

swiftc \
  -parse-as-library \
  -o "$OUT/WindowSnapperTests" \
  MacMonitor/WindowSnapper.swift \
  Tests/WindowSnapperTests.swift

"$OUT/WindowSnapperTests"
