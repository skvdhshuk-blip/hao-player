#!/usr/bin/env bash
# 收集某次上架构建的 LGPL 重新链接材料：dylib、构建脚本、许可证与否决项摘录。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DIST="$ROOT/Vendor/FFmpeg/dist"
VERSION_FILE="$DIST/VERSION"
if [[ ! -f "$VERSION_FILE" ]]; then
  echo "ERROR: missing $VERSION_FILE" >&2
  exit 2
fi
VERSION="$(tr -d '[:space:]' < "$VERSION_FILE")"
OUT="${1:-$ROOT/build/lgpl-relink-$VERSION}"

rm -rf "$OUT"
mkdir -p "$OUT/lib" "$OUT/scripts"

copied=0
for f in "$DIST/lib"/*.dylib; do
  if [[ -e "$f" && ! -L "$f" ]]; then
    cp -f "$f" "$OUT/lib/$(basename "$f")"
    copied=$((copied + 1))
  fi
done
if [[ "$copied" -eq 0 ]]; then
  echo "ERROR: no FFmpeg dylibs in $DIST/lib" >&2
  exit 2
fi

cp -f "$DIST/VERSION" "$OUT/VERSION"
cp -f "$DIST/LICENSE_NOTE" "$OUT/LICENSE_NOTE"
cp -f "$ROOT/scripts/build_ffmpeg_lgpl.sh" "$OUT/scripts/build_ffmpeg_lgpl.sh"
cp -f "$ROOT/Resources/LICENSES/LGPL-2.1.txt" "$OUT/LGPL-2.1.txt"

CONFIG_LOG="$ROOT/Vendor/FFmpeg/src/ffmpeg-${VERSION}/ffbuild/config.log"
if [[ -f "$CONFIG_LOG" ]]; then
  grep -E "disable-gpl|disable-nonfree|disable-version3|enable-gpl|enable-nonfree|enable-version3" \
    "$CONFIG_LOG" > "$OUT/configure-denies.txt" || true
else
  cat > "$OUT/configure-denies.txt" <<EOF
# 本机没有 FFmpeg 源码树 config.log。构建脚本硬编码：
# --disable-gpl --disable-version3 --disable-nonfree
# 见 scripts/build_ffmpeg_lgpl.sh 与 LICENSE_NOTE。
EOF
  cat "$DIST/LICENSE_NOTE" >> "$OUT/configure-denies.txt"
fi

cat > "$OUT/README.txt" <<EOF
Hao Player $VERSION — LGPL 重新链接材料

本目录含该版本动态链接的 FFmpeg dylib、LGPL-2.1 文本、
scripts/build_ffmpeg_lgpl.sh，以及 configure 否决项摘录。

书面提供联系：support@hao.app
自本版本发布起三年，可应要求提供以便用修改过的 LGPL 库重新链接。
EOF

echo "LGPL relink artifacts: $OUT"
echo "dylibs: $copied"
