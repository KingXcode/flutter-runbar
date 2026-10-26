#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
COPY_TO_DESKTOP=0
usage() {
  cat <<'TEXT'
用法：bash scripts/build-app.sh [--desktop] [--help]
桌面入口：./build_macos_app.sh（默认包含 --desktop）
  默认        Release 构建当前机器架构，输出 dist/Flutter Runbar.app
  --desktop   同时复制到 ~/Desktop/Flutter Runbar.app
  --help      显示帮助
替换桌面应用前会先请求旧版正常退出，确认退出后备份并替换，不自动启动新版。
TEXT
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --desktop) COPY_TO_DESKTOP=1 ;;
    --help|-h) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
if [[ "$(uname -s)" != Darwin ]]; then echo '需要 macOS 26+ 和完整 Xcode 26+。' >&2; exit 1; fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo '未找到完整 Xcode，请先安装并在 xcode-select 中选择 Xcode。' >&2
  exit 1
fi
RUN_ID="$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$ROOT/.build/logs"
BUILD_LOG="$ROOT/.build/logs/package-$RUN_ID.log"
STAGING_DIRECTORY=""
cleanup() {
  local status=$?
  if [[ -n "$STAGING_DIRECTORY" ]]; then rm -rf "$STAGING_DIRECTORY"; fi
  if [[ $status -ne 0 ]]; then echo "打包失败，构建日志：$BUILD_LOG" >&2; fi
}
trap cleanup EXIT

# Always replace the whole bundle instead of merging files into an old signature.
# Move the old app aside without modifying its executable, including when it is running.
install_bundle() {
  local destination="$1" label="$2" parent backup=""
  parent="$(dirname "$destination")"
  mkdir -p "$parent"
  STAGING_DIRECTORY="$(mktemp -d "$parent/.runbar-package.XXXXXX")"
  ditto --norsrc --noextattr "$BUILT_APP" "$STAGING_DIRECTORY/Flutter Runbar.app"
  codesign --verify --strict --verbose=2 "$STAGING_DIRECTORY/Flutter Runbar.app"
  if [[ -e "$destination" || -L "$destination" ]]; then
    if [[ -L "$destination" || ! -d "$destination" ]]; then
      echo "目标不是普通应用目录，未替换：$destination" >&2
      return 1
    fi
    local identifier
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$identifier" != dev.kingxcode.flutter-runbar ]]; then
      echo "目标不是 Flutter Runbar，未替换：$destination" >&2
      return 1
    fi
    backup="$ROOT/.build/package-backups/$RUN_ID/$label/Flutter Runbar.app"
    mkdir -p "$(dirname "$backup")"
    mv "$destination" "$backup"
  fi
  if ! mv "$STAGING_DIRECTORY/Flutter Runbar.app" "$destination"; then
    if [[ -n "$backup" ]]; then mv "$backup" "$destination"; fi
    return 1
  fi
  rmdir "$STAGING_DIRECTORY"
  STAGING_DIRECTORY=""
  codesign --verify --strict --verbose=2 "$destination"
  echo "应用：$destination"
  if [[ -n "$backup" ]]; then echo "旧版备份：$backup"; fi
}

DERIVED_DATA="$PWD/.build/xcode"
BUILD_SETTINGS=("CODE_SIGN_IDENTITY=-")
if [[ "${BUILD_SCREENSHOT_PREVIEW:-0}" == 1 ]]; then
  DERIVED_DATA="$PWD/.build/xcode-preview"
  BUILD_SETTINGS+=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=SCREENSHOT_PREVIEW")
fi
echo "开始 Release 构建，日志：$BUILD_LOG"
xcodebuild -project FlutterRunbar.xcodeproj -scheme FlutterRunbar \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" "ARCHS=$(uname -m)" ONLY_ACTIVE_ARCH=YES \
  "${BUILD_SETTINGS[@]}" build 2>&1 | tee "$BUILD_LOG"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/Flutter Runbar.app"
# Local ad hoc signature only. This is NOT Developer ID signing or notarization.
codesign --verify --strict --verbose=2 "$BUILT_APP"
install_bundle "$ROOT/dist/Flutter Runbar.app" dist
INSTALL_PENDING=0
if [[ $COPY_TO_DESKTOP == 1 ]]; then
  mkdir -p "$ROOT/.build/tools"
  INSTALLER="$ROOT/.build/tools/install-desktop-app"
  xcrun swiftc "$ROOT/scripts/install-desktop-app.swift" -o "$INSTALLER"
  INSTALL_LOG="$ROOT/.build/logs/install-$RUN_ID.log"
  if "$INSTALLER" "$BUILT_APP" "$HOME/Desktop/Flutter Runbar.app" \
      "$ROOT/.build/package-backups/$RUN_ID/desktop/Flutter Runbar.app" "$INSTALL_LOG"; then
    echo "安装日志：$INSTALL_LOG"
  else
    status=$?
    if [[ $status == 10 ]]; then INSTALL_PENDING=1
    else exit "$status"
    fi
  fi
fi
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_APP/Contents/Info.plist")"
if [[ $INSTALL_PENDING == 1 ]]; then
  echo "构建完成，独立安装器将退出旧版并替换桌面应用：$VERSION+$BUILD_NUMBER"
else
  echo "打包完成：$VERSION+$BUILD_NUMBER ($(lipo -archs "$BUILT_APP/Contents/MacOS/FlutterRunbar"))"
fi
echo "构建日志：$BUILD_LOG"
