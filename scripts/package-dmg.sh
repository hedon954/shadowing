#!/usr/bin/env bash
# 将 Shadowing 打包为可分发的 .dmg
#
# 用法：
#   ./scripts/package-dmg.sh                    # 本地 / CI 无签名包
#   TEAM_ID=XXXXXXXXXX ./scripts/package-dmg.sh # Developer ID 签名（后续启用）
#
# 产物：build/Shadowing-<version>.dmg
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
XCODE_DIR="$ROOT_DIR/Shadowing"
BUILD_DIR="$ROOT_DIR/build"
INFO_PLIST="$XCODE_DIR/Info.plist"

APP_NAME="Shadowing"
PLIST_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$INFO_PLIST")"
VERSION="${VERSION:-$PLIST_VERSION}"
ARCHIVE_PATH="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_PATH="$BUILD_DIR/${APP_NAME}-${VERSION}.dmg"
DERIVED_DATA_PATH="$BUILD_DIR/DerivedData-Release"
SOURCE_PACKAGES_PATH="$BUILD_DIR/SourcePackages"

TEAM_ID="${TEAM_ID:-}"

echo "╔══════════════════════════════════════════╗"
echo "║   Shadowing DMG 打包                     ║"
echo "╚══════════════════════════════════════════╝"
echo "版本: $VERSION"
echo "产物: $DMG_PATH"
echo ""

XCODE_APP="/Applications/Xcode.app"
CURRENT_DEV_DIR="$(xcode-select -p 2>/dev/null || true)"
if [[ "$CURRENT_DEV_DIR" == *"CommandLineTools"* ]]; then
  if [ -d "$XCODE_APP/Contents/Developer" ]; then
    echo "→ [0/4] 切换 Xcode 开发者目录（需要 sudo）..."
    sudo xcode-select -s "$XCODE_APP/Contents/Developer"
  else
    echo "✗ 未找到 $XCODE_APP，请先安装 Xcode" >&2
    exit 1
  fi
fi

echo "→ [1/4] 生成 Xcode 工程..."
(
  cd "$ROOT_DIR"
  xcodegen generate --spec Shadowing/project.yml
)
echo "   ✓ Shadowing/Shadowing.xcodeproj"

echo "→ [2/4] xcodebuild archive (Release)..."
mkdir -p "$BUILD_DIR"
rm -rf "$ARCHIVE_PATH"

SIGN_ARGS=()
if [ -n "$TEAM_ID" ]; then
  SIGN_ARGS=(
    CODE_SIGN_STYLE=Manual
    CODE_SIGN_IDENTITY="Developer ID Application"
    DEVELOPMENT_TEAM="$TEAM_ID"
  )
  echo "   签名模式: Developer ID（TEAM_ID=$TEAM_ID）"
else
  SIGN_ARGS=(
    CODE_SIGN_IDENTITY="-"
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGNING_ALLOWED=NO
  )
  echo "   签名模式: 不签名"
fi

xcodebuild archive \
  -project "$XCODE_DIR/$APP_NAME.xcodeproj" \
  -scheme "$APP_NAME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED_DATA_PATH" \
  -clonedSourcePackagesDirPath "$SOURCE_PACKAGES_PATH" \
  SKIP_INSTALL=NO \
  "${SIGN_ARGS[@]}"

if [ ! -d "$ARCHIVE_PATH" ]; then
  echo "✗ archive 失败" >&2
  exit 1
fi
echo "   ✓ Archive: $ARCHIVE_PATH"

echo "→ [3/4] 导出 .app..."
rm -rf "$EXPORT_DIR"
mkdir -p "$EXPORT_DIR"

if [ -n "$TEAM_ID" ]; then
  EXPORT_PLIST="$(mktemp /tmp/shadowing-export.XXXXXX.plist)"
  cat > "$EXPORT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>developer-id</string>
	<key>teamID</key>
	<string>${TEAM_ID}</string>
	<key>signingStyle</key>
	<string>manual</string>
</dict>
</plist>
PLIST
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_PLIST"
  rm -f "$EXPORT_PLIST"
else
  cp -R "$ARCHIVE_PATH/Products/Applications/$APP_NAME.app" "$EXPORT_DIR/"
fi

APP_PATH="$EXPORT_DIR/$APP_NAME.app"
if [ ! -d "$APP_PATH" ]; then
  echo "✗ 未找到 $APP_PATH" >&2
  exit 1
fi
echo "   ✓ .app: $APP_PATH"

echo "→ [4/4] 制作 DMG..."
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
cp -R "$APP_PATH" "$DMG_STAGING/"
ln -s /Applications "$DMG_STAGING/Applications"

rm -f "$DMG_PATH"
hdiutil create \
  -volname "$APP_NAME $VERSION" \
  -srcfolder "$DMG_STAGING" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  ✓ 打包完成                              ║"
echo "╚══════════════════════════════════════════╝"
echo "DMG: $DMG_PATH"
if [ -z "$TEAM_ID" ]; then
  echo ""
  echo "提示：当前为无签名 / ad-hoc 包，适合 CI 与本机验证。"
  echo "外部分发前需配置 Developer ID 与公证（见 ADR-0009）。"
fi
