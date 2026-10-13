#!/bin/bash
# 原图 AppIcon-source.png → 整理成 1024 母版（去白底、圆角、投影）→ 生成全部尺寸 → 打包为 Resources/AppIcon.icns
# 用法：./make_icns.sh              使用 AppIcon-source.png
#      ./make_icns.sh 新图片.png     换用另一张原图（会复制为 AppIcon-source.png）
set -euo pipefail
SOURCE="${1:+$(cd "$(dirname "$1")" && pwd)/$(basename "$1")}"
cd "$(dirname "$0")"
if [ -n "$SOURCE" ] && [ "$SOURCE" != "$(pwd)/AppIcon-source.png" ]; then
  cp "$SOURCE" AppIcon-source.png
fi
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
xcrun swiftc prepare_icon.swift -o "$TMP/prepare"
"$TMP/prepare" AppIcon-source.png AppIcon-1024.png
SET="$TMP/AppIcon.iconset"; mkdir -p "$SET"
for s in 16 32 128 256 512; do
  sips -z $s $s AppIcon-1024.png --out "$SET/icon_${s}x${s}.png" >/dev/null
  sips -z $((s*2)) $((s*2)) AppIcon-1024.png --out "$SET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o ../AppIcon.icns
echo "✅ Resources/AppIcon.icns"
