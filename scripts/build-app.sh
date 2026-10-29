#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
COPY_TO_DESKTOP=0
CREATE_DMG=0
SIGNING_IDENTITY="${RUNBAR_SIGNING_IDENTITY:-}"
SIGNING_TEAM=""
usage() {
  cat <<'TEXT'
用法：bash scripts/build-app.sh [--desktop] [--dmg] [--signing-identity 身份] [--help]
App 桌面入口：./build_macos_app.sh
DMG 桌面入口：./build_macos_dmg.sh
  默认                 Release 构建当前机器架构，输出 dist/Runbar.app
  --desktop            同时将当前类型的产物放到桌面
  --dmg                生成 arm64 + x86_64 通用 DMG，不安装或退出 App
  --signing-identity   指定 Developer ID Application 证书指纹/完整名称；- 为 ad hoc
  --help               显示帮助
DMG 默认自动选择唯一可用的 Developer ID Application 证书；也可用 RUNBAR_SIGNING_IDENTITY 指定。
App 默认使用 ad hoc 签名。DMG 无分发证书时会明确报错，可显式指定 - 生成 ad hoc 包。
同名旧产物先备份。替换桌面 App 前请求旧版正常退出；生成 DMG 不退出 App。
不进行 Apple 公证，不上传 App 或 DMG。Developer ID 签名会请求签名时间戳。
TEXT
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --desktop) COPY_TO_DESKTOP=1 ;;
    --dmg) CREATE_DMG=1 ;;
    --signing-identity)
      if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
        echo '--signing-identity 需要证书指纹、完整名称或 -。' >&2; exit 2
      fi
      SIGNING_IDENTITY="$2"; shift ;;
    --help|-h) usage; exit 0 ;;
    *) echo "未知参数：$1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done
if [[ $CREATE_DMG == 1 && "${BUILD_SCREENSHOT_PREVIEW:-0}" == 1 ]]; then
  echo '演示预览构建不能生成分发 DMG。请取消 BUILD_SCREENSHOT_PREVIEW。' >&2; exit 2
fi
if [[ "$(uname -s)" != Darwin ]]; then echo '需要 macOS 26+ 和完整 Xcode 26+。' >&2; exit 1; fi
if ! xcodebuild -version >/dev/null 2>&1; then
  echo '未找到完整 Xcode，请先安装并在 xcode-select 中选择 Xcode。' >&2
  exit 1
fi
RUN_ID="$(TZ=Asia/Shanghai date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$ROOT/.build/logs"
BUILD_LOG="$ROOT/.build/logs/package-$RUN_ID.log"
STAGING_DIRECTORY=""
DMG_WORK_DIRECTORY=""
cleanup() {
  local status=$?
  if [[ -n "$STAGING_DIRECTORY" ]]; then rm -rf "$STAGING_DIRECTORY"; fi
  if [[ -n "$DMG_WORK_DIRECTORY" ]]; then rm -rf "$DMG_WORK_DIRECTORY"; fi
  if [[ $status -ne 0 ]]; then
    if [[ -f "$BUILD_LOG" ]]; then echo "打包失败，构建日志：$BUILD_LOG" >&2
    else echo '打包失败，尚未开始构建。' >&2
    fi
  fi
}
trap cleanup EXIT

select_signing_identity() {
  if [[ "$SIGNING_IDENTITY" == - ]]; then return; fi
  if [[ $CREATE_DMG == 0 && -z "$SIGNING_IDENTITY" ]]; then SIGNING_IDENTITY=-; return; fi
  local identities line pattern selected=-1 index candidate_count=0
  local fingerprints=() names=() teams=()
  identities="$(/usr/bin/security find-identity -v -p codesigning)"
  pattern='([0-9A-Fa-f]{40})[[:space:]]+"(Developer ID Application:.*\(([A-Z0-9]{10})\))"'
  while IFS= read -r line; do
    if [[ "$line" =~ $pattern ]]; then
      fingerprints+=("${BASH_REMATCH[1]}")
      names+=("${BASH_REMATCH[2]}")
      teams+=("${BASH_REMATCH[3]}")
      candidate_count=$((candidate_count + 1))
    fi
  done <<< "$identities"
  if [[ -z "$SIGNING_IDENTITY" ]]; then
    if [[ $candidate_count -ne 1 ]]; then
      echo "找到 $candidate_count 个可用的 Developer ID Application 身份，无法自动选择。" >&2
      echo '请用 --signing-identity 指定指纹/完整名称，或用 - 显式选择 ad hoc 签名。' >&2
      exit 1
    fi
    selected=0
  else
    for ((index=0; index<candidate_count; index++)); do
      if [[ "$SIGNING_IDENTITY" == "${fingerprints[$index]}" || "$SIGNING_IDENTITY" == "${names[$index]}" ]]; then
        if [[ $selected != -1 ]]; then echo '签名身份不唯一，请指定证书指纹。' >&2; exit 1; fi
        selected=$index
      fi
    done
    if [[ $selected == -1 ]]; then echo '未找到指定的有效 Developer ID Application 签名身份。' >&2; exit 1; fi
  fi
  SIGNING_IDENTITY="${fingerprints[$selected]}"
  SIGNING_TEAM="${teams[$selected]}"
  echo "签名身份：${names[$selected]}"
}

# Always replace the whole bundle instead of merging files into an old signature.
# Move the old app aside without modifying its executable, including when it is running.
install_bundle() {
  local destination="$1" label="$2" parent backup=""
  parent="$(dirname "$destination")"
  mkdir -p "$parent"
  STAGING_DIRECTORY="$(mktemp -d "$parent/.runbar-package.XXXXXX")"
  ditto --norsrc --noextattr "$BUILT_APP" "$STAGING_DIRECTORY/Runbar.app"
  codesign --verify --strict --verbose=2 "$STAGING_DIRECTORY/Runbar.app"
  if [[ -e "$destination" || -L "$destination" ]]; then
    if [[ -L "$destination" || ! -d "$destination" ]]; then
      echo "目标不是普通应用目录，未替换：$destination" >&2
      return 1
    fi
    local identifier
    identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$destination/Contents/Info.plist" 2>/dev/null || true)"
    if [[ "$identifier" != dev.kingxcode.flutter-runbar ]]; then
      echo "目标不是 Runbar，未替换：$destination" >&2
      return 1
    fi
    backup="$ROOT/.build/package-backups/$RUN_ID/$label/Runbar.app"
    mkdir -p "$(dirname "$backup")"
    mv "$destination" "$backup"
  fi
  if ! mv "$STAGING_DIRECTORY/Runbar.app" "$destination"; then
    if [[ -n "$backup" ]]; then mv "$backup" "$destination"; fi
    return 1
  fi
  rmdir "$STAGING_DIRECTORY"
  STAGING_DIRECTORY=""
  codesign --verify --strict --verbose=2 "$destination"
  echo "应用：$destination"
  if [[ -n "$backup" ]]; then echo "旧版备份：$backup"; fi
}

# Copy to a temporary sibling and compare before moving the existing DMG.
# A failed replacement restores the original. Never modify a mounted old image.
install_dmg() {
  local source="$1" destination="$2" label="$3" parent backup=""
  parent="$(dirname "$destination")"
  mkdir -p "$parent"
  STAGING_DIRECTORY="$(mktemp -d "$parent/.runbar-dmg.XXXXXX")"
  ditto --norsrc --noextattr "$source" "$STAGING_DIRECTORY/$DMG_FILENAME"
  cmp "$source" "$STAGING_DIRECTORY/$DMG_FILENAME"
  if [[ -e "$destination" || -L "$destination" ]]; then
    if [[ -L "$destination" || ! -f "$destination" ]]; then
      echo "目标不是普通 DMG 文件，未替换：$destination" >&2; return 1
    fi
    backup="$ROOT/.build/package-backups/$RUN_ID/$label/$DMG_FILENAME"
    mkdir -p "$(dirname "$backup")"
    mv "$destination" "$backup"
  fi
  if ! mv "$STAGING_DIRECTORY/$DMG_FILENAME" "$destination"; then
    if [[ -n "$backup" ]]; then mv "$backup" "$destination"; fi
    return 1
  fi
  rmdir "$STAGING_DIRECTORY"; STAGING_DIRECTORY=""
  echo "DMG：$destination"
  if [[ -n "$backup" ]]; then echo "旧版备份：$backup"; fi
}

package_dmg() {
  local architectures minimum_system signature_note signature_suffix
  architectures="$(lipo -archs "$BUILT_APP/Contents/MacOS/Runbar")"
  case " $architectures " in *' arm64 '*) ;; *) echo '产物缺少 arm64 架构。' >&2; return 1 ;; esac
  case " $architectures " in *' x86_64 '*) ;; *) echo '产物缺少 x86_64 架构。' >&2; return 1 ;; esac
  minimum_system="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$BUILT_APP/Contents/Info.plist")"
  if [[ "$SIGNING_IDENTITY" == - ]]; then
    signature_suffix=adhoc
    signature_note='此包使用 ad hoc 签名，没有 Developer ID 分发签名，未进行 Apple 公证。'
  else
    signature_suffix=signed
    signature_note='此包使用 Developer ID 签名，未进行 Apple 公证。'
  fi
  DMG_FILENAME="Runbar-$VERSION-$BUILD_NUMBER-universal-$signature_suffix.dmg"
  DMG_WORK_DIRECTORY="$(mktemp -d /private/tmp/runbar-dmg.XXXXXX)"
  mkdir -p "$DMG_WORK_DIRECTORY/image-root"
  ditto --norsrc --noextattr "$BUILT_APP" "$DMG_WORK_DIRECTORY/image-root/Runbar.app"
  codesign --verify --deep --strict --verbose=2 "$DMG_WORK_DIRECTORY/image-root/Runbar.app"
  ln -s /Applications "$DMG_WORK_DIRECTORY/image-root/Applications"
  cat > "$DMG_WORK_DIRECTORY/image-root/安装说明.txt" <<TEXT
Runbar $VERSION ($BUILD_NUMBER)

系统要求：macOS $minimum_system 或更新版本。
通用架构：Apple Silicon（arm64）和 Intel（x86_64）。

将 Runbar.app 拖到 Applications（应用程序）文件夹，推出磁盘映像，再从“应用程序”打开。
默认从系统菜单栏的终端图标进入管理窗口；可在设置中开启 Dock 显示。

$signature_note
如果 macOS 阻止打开，确认安装包来源可信后，可在“系统设置 > 隐私与安全性”选择“仍要打开”。不需要关闭系统安全功能。
Apple 说明：https://support.apple.com/guide/mac-help/mh40617/mac

Runbar 本身不需要 Flutter、FVM 或 Xcode；执行项目命令时仍需安装对应工具链。
安装包不包含原电脑的项目、运行日志或个人配置，首次运行请添加项目或连接 Flutter App。
TEXT
  hdiutil create -volname Runbar -srcfolder "$DMG_WORK_DIRECTORY/image-root" \
    -fs HFS+ -format UDZO -imagekey zlib-level=9 "$DMG_WORK_DIRECTORY/$DMG_FILENAME"
  if [[ "$SIGNING_IDENTITY" == - ]]; then
    codesign --sign - --timestamp=none "$DMG_WORK_DIRECTORY/$DMG_FILENAME"
  else
    codesign --sign "$SIGNING_IDENTITY" --timestamp "$DMG_WORK_DIRECTORY/$DMG_FILENAME"
  fi
  codesign --verify --strict --verbose=2 "$DMG_WORK_DIRECTORY/$DMG_FILENAME"
  hdiutil verify "$DMG_WORK_DIRECTORY/$DMG_FILENAME"
  install_dmg "$DMG_WORK_DIRECTORY/$DMG_FILENAME" "$ROOT/dist/$DMG_FILENAME" dist-dmg
  (cd "$ROOT/dist"; shasum -a 256 "$DMG_FILENAME" > "$DMG_FILENAME.sha256")
  if [[ $COPY_TO_DESKTOP == 1 ]]; then
    install_dmg "$ROOT/dist/$DMG_FILENAME" "$HOME/Desktop/$DMG_FILENAME" desktop-dmg
  fi
  echo "DMG 打包完成：$VERSION+$BUILD_NUMBER ($architectures)，未公证，未上传构建产物。"
}

select_signing_identity
DERIVED_DATA="$PWD/.build/xcode"
BUILD_ARCHITECTURES="$(uname -m)"
BUILD_ACTIVE_ARCH=YES
BUILD_SETTINGS=("CODE_SIGN_IDENTITY=$SIGNING_IDENTITY")
if [[ "$SIGNING_IDENTITY" != - ]]; then
  BUILD_SETTINGS+=("CODE_SIGN_STYLE=Manual" "DEVELOPMENT_TEAM=$SIGNING_TEAM" "CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO" "OTHER_CODE_SIGN_FLAGS=--timestamp")
fi
if [[ $CREATE_DMG == 1 ]]; then
  DERIVED_DATA="$PWD/.build/xcode-universal"
  BUILD_ARCHITECTURES='arm64 x86_64'
  BUILD_ACTIVE_ARCH=NO
fi
if [[ "${BUILD_SCREENSHOT_PREVIEW:-0}" == 1 ]]; then
  DERIVED_DATA="$PWD/.build/xcode-preview"
  BUILD_SETTINGS+=("SWIFT_ACTIVE_COMPILATION_CONDITIONS=SCREENSHOT_PREVIEW")
fi
echo "开始 Release 构建，日志：$BUILD_LOG"
xcodebuild -project FlutterRunbar.xcodeproj -scheme FlutterRunbar \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath "$DERIVED_DATA" "ARCHS=$BUILD_ARCHITECTURES" "ONLY_ACTIVE_ARCH=$BUILD_ACTIVE_ARCH" \
  "${BUILD_SETTINGS[@]}" build 2>&1 | tee "$BUILD_LOG"
BUILT_APP="$DERIVED_DATA/Build/Products/Release/Runbar.app"
codesign --verify --strict --verbose=2 "$BUILT_APP"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILT_APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILT_APP/Contents/Info.plist")"
if [[ ! "$VERSION" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ || ! "$BUILD_NUMBER" =~ ^[0-9A-Za-z][0-9A-Za-z._+-]*$ ]]; then
  echo '版本号或构建号不适合用作产物文件名。' >&2; exit 1
fi
if [[ $CREATE_DMG == 1 ]]; then
  package_dmg
  echo "构建日志：$BUILD_LOG"
  exit 0
fi
install_bundle "$ROOT/dist/Runbar.app" dist
INSTALL_PENDING=0
if [[ $COPY_TO_DESKTOP == 1 ]]; then
  mkdir -p "$ROOT/.build/tools"
  INSTALLER="$ROOT/.build/tools/install-desktop-app"
  xcrun swiftc "$ROOT/scripts/install-desktop-app.swift" -o "$INSTALLER"
  INSTALL_LOG="$ROOT/.build/logs/install-$RUN_ID.log"
  if "$INSTALLER" "$BUILT_APP" "$HOME/Desktop/Runbar.app" \
      "$ROOT/.build/package-backups/$RUN_ID/desktop/Runbar.app" "$INSTALL_LOG"; then
    echo "安装日志：$INSTALL_LOG"
  else
    status=$?
    if [[ $status == 10 ]]; then INSTALL_PENDING=1
    else exit "$status"
    fi
  fi
fi
if [[ $INSTALL_PENDING == 1 ]]; then
  echo "构建完成，独立安装器将退出旧版并替换桌面应用：$VERSION+$BUILD_NUMBER"
else
  echo "打包完成：$VERSION+$BUILD_NUMBER ($(lipo -archs "$BUILT_APP/Contents/MacOS/Runbar"))"
fi
echo "构建日志：$BUILD_LOG"
