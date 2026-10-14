#!/bin/bash
# 构建 MacBox.app：swiftc 编译 → 组装 .app → 带虚拟化 entitlement 的 ad-hoc 签名
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:-release}"
OPT="-O"; [ "$MODE" = "debug" ] && OPT="-Onone -g"

BUILD_DIR="build"
APP="$BUILD_DIR/MacBox.app"
mkdir -p "$BUILD_DIR"

SDKROOT="${SDKROOT:-$(xcrun --show-sdk-path)}"
echo "SDK: $SDKROOT"

SOURCES=$(find Sources/MacBox -name '*.swift')
# shellcheck disable=SC2086
xcrun swiftc $OPT -swift-version 6 -parse-as-library \
  -default-isolation MainActor \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances \
  -sdk "$SDKROOT" \
  -target arm64-apple-macos26.0 \
  -module-name MacBox \
  -o "$BUILD_DIR/MacBox" $SOURCES

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BUILD_DIR/MacBox" "$APP/Contents/MacOS/MacBox"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 系统菜单、访达里的文稿类型名称按这里声明的语言显示；界面文字本身见 Localization.swift
cp -R Resources/*.lproj "$APP/Contents/Resources/"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Virtualization.framework 需要 com.apple.security.virtualization entitlement
codesign --force --sign - --options runtime \
  --entitlements Resources/MacBox.entitlements "$APP"

echo "✅ 已构建: $(pwd)/$APP"
