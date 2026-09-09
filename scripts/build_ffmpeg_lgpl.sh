#!/usr/bin/env bash
# 构建可嵌入 Mac App Store 的 LGPL-2.1 FFmpeg 动态库（arm64 / macOS 26）。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${FFMPEG_VERSION:-7.1.1}"
SRC_DIR="$ROOT/Vendor/FFmpeg/src/ffmpeg-${VERSION}"
PREFIX="$ROOT/Vendor/FFmpeg/dist"
JOBS="$(sysctl -n hw.ncpu)"

if [[ -f "$PREFIX/lib/libavformat.dylib" && "${FFMPEG_FORCE_REBUILD:-}" != "1" ]]; then
  echo "FFmpeg already at $PREFIX (set FFMPEG_FORCE_REBUILD=1 to rebuild)"
  exit 0
fi

mkdir -p "$ROOT/Vendor/FFmpeg/src" "$PREFIX"

if [[ ! -d "$SRC_DIR" ]]; then
  ARCHIVE="$ROOT/Vendor/FFmpeg/src/ffmpeg-${VERSION}.tar.xz"
  if [[ ! -f "$ARCHIVE" ]]; then
    URL="https://ffmpeg.org/releases/ffmpeg-${VERSION}.tar.xz"
    echo "Downloading $URL"
    curl -L --fail --retry 3 -o "$ARCHIVE" "$URL"
  fi
  tar -xJf "$ARCHIVE" -C "$ROOT/Vendor/FFmpeg/src"
fi

cd "$SRC_DIR"

# 禁止 GPL / nonfree / version3 / 网络协议。只开本地 demux + VT 解码。
./configure \
  --prefix="$PREFIX" \
  --enable-shared \
  --disable-static \
  --disable-gpl \
  --disable-version3 \
  --disable-nonfree \
  --disable-doc \
  --disable-htmlpages \
  --disable-manpages \
  --disable-podpages \
  --disable-txtpages \
  --disable-network \
  --disable-programs \
  --disable-autodetect \
  --disable-avdevice \
  --disable-avfilter \
  --disable-postproc \
  --enable-avcodec \
  --enable-avformat \
  --enable-avutil \
  --enable-swscale \
  --enable-swresample \
  --enable-videotoolbox \
  --enable-zlib \
  --enable-protocol=file \
  --enable-hwaccel=h264_videotoolbox \
  --enable-hwaccel=hevc_videotoolbox \
  --enable-hwaccel=mpeg4_videotoolbox \
  --enable-hwaccel=vp9_videotoolbox \
  --enable-hwaccel=av1_videotoolbox \
  --enable-decoder=h264,hevc,mpeg4,vp8,vp9,av1,aac,flac,opus,vorbis,mp3,ac3,eac3,pcm_s16le,pcm_s24le,alac \
  --enable-demuxer=matroska,mov,ogg,flac,mpegts,avi,wav,mp3,aac \
  --enable-parser=h264,hevc,aac,opus,vorbis,flac,vp8,vp9,av1 \
  --enable-bsf=h264_mp4toannexb,hevc_mp4toannexb,extract_extradata \
  --extra-cflags="-mmacosx-version-min=26.0 -arch arm64" \
  --extra-ldflags="-mmacosx-version-min=26.0 -arch arm64 -framework VideoToolbox -framework CoreMedia -framework CoreVideo -framework CoreFoundation -lz" \
  --arch=arm64 \
  --cc=clang

make -j"$JOBS"
make install

export PREFIX
python3 - <<'PY'
import os, subprocess
from pathlib import Path
prefix = Path(os.environ["PREFIX"])
lib = prefix / "lib"
dylibs = [p for p in lib.glob("*.dylib") if p.is_file() and not p.is_symlink()]
for dylib in dylibs:
    name = dylib.name
    subprocess.check_call(["install_name_tool", "-id", f"@rpath/{name}", str(dylib)])
    out = subprocess.check_output(["otool", "-L", str(dylib)], text=True)
    for line in out.splitlines()[1:]:
        path = line.strip().split(" ", 1)[0]
        if path.startswith(str(prefix / "lib")):
            dep = os.path.basename(path)
            subprocess.check_call(["install_name_tool", "-change", path, f"@rpath/{dep}", str(dylib)])
print("rewrote install names to @rpath")
PY

# configure 日志里必须能搜到这些否决项，供上架材料核对。
if grep -E "enable-gpl|enable-nonfree|enable-version3" "$SRC_DIR/ffbuild/config.log" | grep -v disable; then
  echo "ERROR: GPL/nonfree/version3 leaked into config" >&2
  exit 1
fi

echo "FFmpeg LGPL installed to $PREFIX"
echo "$VERSION" > "$PREFIX/VERSION"
echo "LGPL-2.1-or-later (no --enable-gpl / --enable-nonfree / --enable-version3)" > "$PREFIX/LICENSE_NOTE"
