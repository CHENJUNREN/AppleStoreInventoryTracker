#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_source="Tests/RegressionTests.swift"
case "${1:-}" in
  "") ;;
  --live) test_source="Tests/LivePickupCheck.swift" ;;
  *) echo "Usage: $0 [--live]" >&2; exit 2 ;;
esac
test_build_dir="$(mktemp -d "${TMPDIR:-/tmp}/apple-inventory-tests.XXXXXX")"
trap 'rm -rf "$test_build_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  -module-cache-path "${TMPDIR:-/tmp}/apple-inventory-swift-cache" \
  AppleStoreInventoryTracker/Inventory.swift \
  AppleStoreInventoryTracker/ProductPresentation.swift \
  AppleStoreInventoryTracker/InventoryClient.swift \
  AppleStoreInventoryTracker/InventoryNotifier.swift \
  AppleStoreInventoryTracker/ContentViewModel.swift \
  "$test_source" -o "$test_build_dir/RegressionTests"
"$test_build_dir/RegressionTests"
