#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p screenshots
python3 scripts/seed-screenshot-fixture.py
open -n 'dist/Flutter Runbar.app' --args --capture-real-menu "$PWD/screenshots"
# Wait for the app's bounded public-API attempt, never grant permissions.
for attempt in {1..15}; do
  if [[ -f screenshots/actual-menu-blocked.txt ]]; then
    cat screenshots/actual-menu-blocked.txt >&2
    exit 1
  fi
  if [[ -f screenshots/actual-menu-ready.txt ]]; then
    # Full main display intentionally retains the system menu bar and anchor context.
    screencapture -x -D 1 screenshots/actual-menu-popup.png
    sips -g pixelWidth -g pixelHeight screenshots/actual-menu-popup.png
    cat screenshots/actual-menu-ready.txt
    exit 0
  fi
  sleep 1
done
echo 'Actual popup readiness was not confirmed; no substitute capture produced.' >&2
exit 1
