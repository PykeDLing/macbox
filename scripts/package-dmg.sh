#!/bin/bash
# 打包发布用的 dmg：release 构建 → 组装（App + Applications 快捷方式 + 卷图标）→ 压缩为 dist/MacBox-<版本>.dmg
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh release
APP="build/MacBox.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$APP/Contents/Info.plist")
NAME="MacBox-$VERSION"
mkdir -p dist
OUT="dist/$NAME.dmg"

TMP=$(mktemp -d)
MOUNT="$TMP/mount"
cleanup() {
  hdiutil detach -quiet "$MOUNT" 2>/dev/null || true
  rm -rf "$TMP"
}
trap cleanup EXIT

# 先做可写映像，放好内容和卷图标，再转成压缩的只读映像
hdiutil create -quiet -size 200m -fs APFS -volname "MacBox" "$TMP/rw.dmg"
mkdir -p "$MOUNT"
hdiutil attach -quiet -nobrowse -noautoopen -mountpoint "$MOUNT" "$TMP/rw.dmg"
ditto "$APP" "$MOUNT/MacBox.app"
ln -s /Applications "$MOUNT/Applications"
cp Resources/AppIcon.icns "$MOUNT/.VolumeIcon.icns"
SetFile -a C "$MOUNT" 2>/dev/null || true # 让访达使用卷图标（需要 Command Line Tools）
hdiutil detach -quiet "$MOUNT"

rm -f "$OUT"
hdiutil convert -quiet "$TMP/rw.dmg" -format ULMO -o "$OUT" # LZMA 压缩，macOS 10.15+ 可打开
codesign --force --sign - "$OUT"

(cd dist && shasum -a 256 "$NAME.dmg" | tee "$NAME.dmg.sha256")
echo "✅ $OUT"
