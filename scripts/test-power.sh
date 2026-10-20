#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/apple-power-tests.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library \
  -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "${TMPDIR:-/tmp}/apple-inventory-swift-cache" \
  AppleStoreInventoryTracker/Monitoring/MonitoringActivity.swift \
  Tests/MonitoringActivityProcessTests.swift \
  -o "$test_build_dir/MonitoringActivityProcessTests"
"$test_build_dir/MonitoringActivityProcessTests"
