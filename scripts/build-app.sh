#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then echo 'macOS 26 + Xcode 26 required' >&2; exit 1; fi
export MACOSX_DEPLOYMENT_TARGET=26.0
if [[ "${BUILD_SCREENSHOT_PREVIEW:-0}" == 1 ]]; then
  swift build -c release -Xswiftc -DSCREENSHOT_PREVIEW
else
  swift build -c release
fi
BIN_DIR="$(swift build -c release --show-bin-path)"
APP="$PWD/dist/Flutter Runbar.app"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/FlutterRunbar" "$APP/Contents/MacOS/FlutterRunbar"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Flutter Runbar</string>
<key>CFBundleDisplayName</key><string>Flutter Runbar</string>
<key>CFBundleIdentifier</key><string>dev.kingxcode.flutter-runbar</string>
<key>CFBundleVersion</key><string>3</string>
<key>CFBundleShortVersionString</key><string>0.2.1</string>
<key>CFBundleExecutable</key><string>FlutterRunbar</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>LSUIElement</key><true/>
<key>NSHighResolutionCapable</key><true/>
</dict></plist>
PLIST
# Local ad hoc signature only. This is NOT Developer ID signing or notarization.
codesign --force --sign - "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "$APP"
