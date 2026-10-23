#!/bin/bash
# Requires an unlocked macOS desktop. Uses only isolated sample data.
set -euo pipefail
cd "$(dirname "$0")/.."
activity_test_dir="$(mktemp -d "${TMPDIR:-/tmp}/activity-ui.XXXXXX")"
trap 'rm -rf "$activity_test_dir"' EXIT
python3 - "$activity_test_dir/Probe.swift" <<'PY'
import sys
from pathlib import Path
source = Path('AppleStoreInventoryTracker/Views/ContentView.swift').read_text()
views = source[source.index('private struct ActivityBottomPreference'):]
marker = '    let entry: TaskActivity\n    var body: some View {'
assert views.count(marker) == 1
views = views.replace(marker, marker + '\n        let _ = { Probe.rows += 1 }()')
model = Path('AppleStoreInventoryTracker/Models/ScanTask.swift').read_text()
model = model[model.index('struct TaskActivity:'):]
probe = Path('Tests/ActivityRenderingProbe.swift').read_text()
Path(sys.argv[1]).write_text('import SwiftUI\nimport AppKit\n' + model + views + probe)
PY
xcrun swiftc -parse-as-library "$activity_test_dir/Probe.swift" -o "$activity_test_dir/Probe"
"$activity_test_dir/Probe"
