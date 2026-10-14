#!/bin/bash
# Build, sign and package Relisten for the Mac App Store; optionally validate/upload.
#
#   PROFILE=path/to/Relisten_MAS.provisionprofile scripts/release-mas.sh [validate|upload]
#
# Needs in the login keychain: "Apple Distribution" + "3rd Party Mac Developer Installer" identities.
# Upload uses the App Store Connect API key (ASC_KEY_ID / ASC_ISSUER / API_PRIVATE_KEYS_DIR).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TEAM=97XBW2A43H
BUNDLE_ID=com.wangjianshuo.relisten
APP_SIGN="Apple Distribution: Jian Shuo Wang ($TEAM)"
PKG_SIGN="3rd Party Mac Developer Installer: Jian Shuo Wang ($TEAM)"
PROFILE="${PROFILE:?set PROFILE to the Mac App Store provisioning profile}"
OUT="$ROOT/build/mas"
ACTION="${1:-package}"

[ -x vendor/ffmpeg/ffmpeg ] || { echo "vendor/ffmpeg missing: run scripts/build-ffmpeg.sh" >&2; exit 1; }

# Each upload needs a new build number.
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

xcodegen generate -q
xcodebuild -project Relisten.xcodeproj -scheme Relisten -configuration Release -derivedDataPath build/dd \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" CODE_SIGN_IDENTITY=- build -quiet

rm -rf "$OUT" && mkdir -p "$OUT"
cp -R build/dd/Build/Products/Release/Relisten.app "$OUT/"
APP="$OUT/Relisten.app"
cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
chmod -R u+rwX,go+rX "$APP"   # every file must be world-readable (ITMS 90255)

ENT="$OUT/app.entitlements"
cp Mac/Relisten.entitlements "$ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $TEAM.$BUNDLE_ID" "$ENT"
/usr/libexec/PlistBuddy -c "Add :com.apple.developer.team-identifier string $TEAM" "$ENT"

for b in ffmpeg ffprobe; do
  codesign -f -s "$APP_SIGN" --entitlements scripts/helper.entitlements "$APP/Contents/Helpers/$b"
done
codesign -f -s "$APP_SIGN" --entitlements "$ENT" "$APP"
codesign --verify --deep --strict --verbose=1 "$APP"
codesign -d --entitlements - "$APP/Contents/Helpers/ffmpeg" 2>/dev/null | grep -q inherit

productbuild --component "$APP" /Applications --sign "$PKG_SIGN" "$OUT/Relisten.pkg"
pkgutil --check-signature "$OUT/Relisten.pkg" | head -3
echo "package: $OUT/Relisten.pkg (build $BUILD_NUMBER)"

case "$ACTION" in
  validate|upload)
    : "${ASC_KEY_ID:?}" "${ASC_ISSUER:?}" "${API_PRIVATE_KEYS_DIR:?}"
    flag=$([ "$ACTION" = validate ] && echo --validate-app || echo --upload-app)
    xcrun altool "$flag" -f "$OUT/Relisten.pkg" -t macos --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER"
    ;;
esac
