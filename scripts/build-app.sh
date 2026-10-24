#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then echo 'macOS 26 + Xcode 26 required' >&2; exit 1; fi
DERIVED_DATA="$PWD/.build/xcode"
BUILD_SETTINGS=("CODE_SIGN_IDENTITY=-")
if [[ "${BUILD_SCREENSHOT_PREVIEW:-0}" == 1 ]]; then
  BUILD_SETTINGS+=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=SCREENSHOT_PREVIEW")
fi
xcodebuild -project FlutterRunbar.xcodeproj -scheme FlutterRunbar \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" "ARCHS=$(uname -m)" ONLY_ACTIVE_ARCH=YES \
  "${BUILD_SETTINGS[@]}" build
APP="$PWD/dist/Flutter Runbar.app"
# Copy the complete Xcode app bundle, including metadata and any resources.
# Local ad hoc signature only. This is NOT Developer ID signing or notarization.
mkdir -p "$PWD/dist"
ditto "$DERIVED_DATA/Build/Products/Release/Flutter Runbar.app" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "$APP"
