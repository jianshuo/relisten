#!/bin/bash
# Xcode post-build phase: embed the LGPL ffmpeg/ffprobe helpers (built by scripts/build-ffmpeg.sh)
# into Contents/Helpers, sign them as sandbox-inheriting helpers, and ship the license + source notice.
set -euo pipefail

SRC="$PROJECT_DIR/vendor/ffmpeg"
DST="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Helpers"
LIC="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/Licenses"

if [ ! -x "$SRC/ffmpeg" ] || [ ! -x "$SRC/ffprobe" ]; then
  echo "warning: vendor/ffmpeg missing — run scripts/build-ffmpeg.sh (falling back to system ffmpeg in unsandboxed runs)"
  exit 0
fi

mkdir -p "$DST" "$LIC"
cp -f "$SRC/ffmpeg" "$SRC/ffprobe" "$DST/"
install -m 644 "$SRC/COPYING.LGPLv2.1" "$LIC/FFmpeg-LGPLv2.1.txt"
VERSION="$(cat "$SRC/VERSION")"
cat > "$LIC/FFmpeg-NOTICE.txt" <<EOF
Relisten includes the command-line tools ffmpeg and ffprobe from FFmpeg $VERSION
(https://ffmpeg.org), licensed under the GNU Lesser General Public License v2.1 or later.
They are bundled unmodified as separate programs in Relisten.app/Contents/Helpers.

Source code: https://ffmpeg.org/releases/ffmpeg-$VERSION.tar.xz
Configure flags (LGPL only — no --enable-gpl, no --enable-nonfree):
  --enable-static --disable-shared --disable-autodetect --enable-videotoolbox
  --enable-audiotoolbox --enable-zlib --enable-iconv --disable-ffplay --disable-doc
  --disable-network --disable-avdevice --disable-debug --enable-small

FFmpeg is a trademark of Fabrice Bellard, originator of the FFmpeg project.
The full license text is in FFmpeg-LGPLv2.1.txt next to this file.
EOF

IDENTITY="${EXPANDED_CODE_SIGN_IDENTITY:-}"
[ -z "$IDENTITY" ] && IDENTITY="-"
for b in ffmpeg ffprobe; do
  codesign -f -s "$IDENTITY" --entitlements "$PROJECT_DIR/scripts/helper.entitlements" "$DST/$b"
done
