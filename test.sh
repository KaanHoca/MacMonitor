#!/bin/bash
# MacMonitor: build and run the unit tests (plain swiftc, no Xcode project)
set -e

cd "$(dirname "$0")"

OUT=$(mktemp -d)
trap 'rm -rf "$OUT"' EXIT

# Each suite is a standalone executable: the code under test plus its tests.
run_suite() {
  local name=$1
  shift
  swiftc -parse-as-library -o "$OUT/$name" "$@"
  "$OUT/$name"
}

run_suite WindowSnapperTests MacMonitor/WindowSnapper.swift Tests/WindowSnapperTests.swift
run_suite WidgetChromeTests MacMonitor/WidgetChrome.swift Tests/WidgetChromeTests.swift
