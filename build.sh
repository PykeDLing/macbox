#!/bin/bash
# 构建 MacBox.app：swiftc 编译 → 同步、编译界面文字（String Catalog）→ 组装 .app → 带虚拟化 entitlement 的 ad-hoc 签名
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
# swiftc 顺带写出代码里用到的界面文字（每个源文件一个 .stringsdata），和 Xcode 构建时一样
STRINGS_DIR="$BUILD_DIR/strings"
rm -rf "$STRINGS_DIR"
mkdir -p "$STRINGS_DIR"
# shellcheck disable=SC2086
xcrun swiftc $OPT -swift-version 6 -parse-as-library \
  -default-isolation MainActor \
  -enable-upcoming-feature NonisolatedNonsendingByDefault \
  -enable-upcoming-feature InferIsolatedConformances \
  -sdk "$SDKROOT" \
  -target arm64-apple-macos26.0 \
  -module-name MacBox \
  -emit-localized-strings -emit-localized-strings-path "$STRINGS_DIR" \
  -o "$BUILD_DIR/MacBox" $SOURCES

# 界面文字：新用到的加进 Localizable.xcstrings、不再用的标成 stale（会改动这个文件，和 Xcode 一样），在 Xcode 里打开它补英文译文。
# 表名就是文件名，所以只同步 Localizable；InfoPlist.xcstrings 是 Info.plist 里的文字，手动维护
xcrun xcstringstool sync Resources/Localizable.xcstrings --stringsdata "$STRINGS_DIR"/*.stringsdata

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
mv "$BUILD_DIR/MacBox" "$APP/Contents/MacOS/MacBox"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 编译成 en.lproj 里的 .strings、.stringsdict
for catalog in Resources/*.xcstrings; do
  xcrun xcstringstool compile "$catalog" --output-directory "$APP/Contents/Resources"
done
# 简体中文是源语言，键就是原文，编译不出文件；但开发语言是英文（偏好语言里中英文都没有时显示英文），
# 简体中文这边没有某张表时，系统会退回去查英文的那张。所以给 en.lproj 里的每张表在 zh-Hans.lproj 放一张空表：
# 表在、键不在里面，就直接用键本身（中文原文）
ZH_LPROJ="$APP/Contents/Resources/zh-Hans.lproj"
mkdir -p "$ZH_LPROJ"
for table in "$APP/Contents/Resources/en.lproj"/*; do
  plutil -create xml1 "$ZH_LPROJ/$(basename "$table")"
done
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
fi

# Virtualization.framework 需要 com.apple.security.virtualization entitlement
codesign --force --sign - --options runtime \
  --entitlements Resources/MacBox.entitlements "$APP"

echo "✅ 已构建: $(pwd)/$APP"
