#!/bin/bash
# Builds LGPL-only, statically linked, universal ffmpeg + ffprobe into vendor/ffmpeg/.
# No --enable-gpl / --enable-nonfree, no autodetected third-party libs: only Apple system
# frameworks (VideoToolbox, AudioToolbox) plus zlib/iconv from the SDK.
set -euo pipefail

VERSION="${FFMPEG_VERSION:-8.1.1}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="${FFMPEG_WORK:-$ROOT/build/ffmpeg}"
OUT="$ROOT/vendor/ffmpeg"
MIN_MACOS=14.0

mkdir -p "$WORK" "$OUT"
cd "$WORK"
if [ ! -d "ffmpeg-$VERSION" ]; then
  curl -fL --retry 3 -o "ffmpeg-$VERSION.tar.xz" "https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz"
  tar xf "ffmpeg-$VERSION.tar.xz"
fi

for ARCH in arm64 x86_64; do
  B="$WORK/build-$ARCH"
  rm -rf "$B" && mkdir -p "$B" && cd "$B"
  "$WORK/ffmpeg-$VERSION/configure" \
    --prefix="$B/install" \
    --arch="$ARCH" --target-os=darwin --enable-cross-compile \
    --cc="clang -arch $ARCH" \
    --extra-cflags="-mmacosx-version-min=$MIN_MACOS" \
    --extra-ldflags="-mmacosx-version-min=$MIN_MACOS" \
    --extra-libs="-liconv" \
    --enable-static --disable-shared \
    --disable-autodetect \
    --enable-videotoolbox --enable-audiotoolbox --enable-zlib --enable-iconv \
    --disable-ffplay --disable-doc --disable-network --disable-avdevice \
    --disable-debug --enable-small \
    $( [ "$ARCH" = x86_64 ] && echo --disable-x86asm ) \
    > configure.log
  grep -q "^License: LGPL" configure.log || { echo "not an LGPL configuration" >&2; exit 1; }
  make -j"$(sysctl -n hw.ncpu)" ffmpeg ffprobe > make.log 2>&1
  cd "$WORK"
done

for BIN in ffmpeg ffprobe; do
  lipo -create "$WORK/build-arm64/$BIN" "$WORK/build-x86_64/$BIN" -output "$OUT/$BIN"
  strip -x "$OUT/$BIN"
done
"$OUT/ffmpeg" -hide_banner -L 2>/dev/null | head -3 > "$OUT/LICENSE-SUMMARY.txt" || true
cp "$WORK/ffmpeg-$VERSION/COPYING.LGPLv2.1" "$OUT/COPYING.LGPLv2.1"
echo "$VERSION" > "$OUT/VERSION"
lipo -info "$OUT/ffmpeg" "$OUT/ffprobe"
"$OUT/ffmpeg" -hide_banner -version | head -3
