#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots
cat > screenshots/provenance.txt <<'TEXT'
Actual macOS application window capture from a GitHub-hosted macOS26 runner.
The displayed project, commands, history and logs are explicit fictional fixtures.
No Flutter command was executed. No user computer was accessed.
No Accessibility or Screen Recording permissions were granted or changed.
TEXT
python3 scripts/seed-screenshot-fixture.py
open -n 'dist/Flutter Runbar.app'
sleep 6
cat > screenshots/find-window.swift <<'SWIFT'
import Foundation
import CoreGraphics
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for info in windows {
    guard let owner = info[kCGWindowOwnerName as String] as? String,
          owner.contains("Flutter"),
          let bounds = info[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, width > 600,
          let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
          let id = info[kCGWindowNumber as String] as? Int else { continue }
    print(id)
    exit(0)
}
fputs("No visible Flutter Runbar management window. GUI capture unavailable.\n", stderr)
exit(1)
SWIFT
WINDOW_ID="$(swift screenshots/find-window.swift)"
# If macOS denies capture, fail and report it. Do not change TCC or permissions.
screencapture -x -l "$WINDOW_ID" screenshots/main-window.png
sips -g pixelWidth -g pixelHeight screenshots/main-window.png
