#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots
if [[ ! -f "$HOME/Library/Application Support/FlutterRunbar/configuration.json" ]]; then
  python3 scripts/seed-screenshot-fixture.py
fi
cat > screenshots/find-main-for-pid.swift <<'SWIFT'
import Foundation
import CoreGraphics
let pid = Int(CommandLine.arguments[1])!
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
for info in windows {
    guard let owner = info[kCGWindowOwnerPID as String] as? Int, owner == pid,
          let bounds = info[kCGWindowBounds as String] as? [String: Any],
          let width = bounds["Width"] as? Double, width >= 860,
          let height = bounds["Height"] as? Double, height >= 580,
          let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
          let id = info[kCGWindowNumber as String] as? Int else { continue }
    print(id); exit(0)
}
fputs("No visible management window for the exact preview child process.\n", stderr)
exit(1)
SWIFT
APP_PID=''
cleanup() {
  if [[ -n "$APP_PID" ]]; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=''
  fi
}
trap cleanup EXIT
for variant in light dark light-small; do
  theme="$variant"
  if [[ "$variant" == light-small ]]; then
    theme=light
    'dist/Flutter Runbar.app/Contents/MacOS/FlutterRunbar' --screenshot-appearance "$theme" --screenshot-main-only --screenshot-small-window &
  else
    'dist/Flutter Runbar.app/Contents/MacOS/FlutterRunbar' --screenshot-appearance "$theme" --screenshot-main-only &
  fi
  APP_PID=$!
  sleep 6
  WINDOW_ID="$(swift screenshots/find-main-for-pid.swift "$APP_PID")"
  screencapture -x -l "$WINDOW_ID" "screenshots/main-window-$variant.png"
  sips -g pixelWidth -g pixelHeight "screenshots/main-window-$variant.png"
  cleanup
done
cat >> screenshots/provenance.txt <<'TEXT'
Main-window light/dark variants set NSApp.appearance only inside the screenshot build.
No system appearance setting or permission changed. Light-small uses the 880x620 target.
Every variant captures the actual native window of its explicitly launched child PID.
TEXT
