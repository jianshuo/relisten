#!/bin/bash
# Archive, export and (optionally) upload the iPhone/iPad build to App Store Connect.
#
#   scripts/release-ios.sh [package|upload]
#
# Needs: "Apple Distribution" identity in the keychain and the "Relisten iOS App Store" profile installed.
# Upload uses the App Store Connect API key (ASC_KEY_ID / ASC_ISSUER / API_PRIVATE_KEYS_DIR).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
TEAM=97XBW2A43H
BUNDLE_ID=com.wangjianshuo.relisten
PROFILE_NAME="Relisten iOS App Store"
OUT="$ROOT/build/ios"
ACTION="${1:-package}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M)}"

xcodegen generate -q
rm -rf "$OUT" && mkdir -p "$OUT"
xcodebuild -project Relisten.xcodeproj -scheme RelistenIOS -configuration Release \
  -destination 'generic/platform=iOS' -archivePath "$OUT/Relisten.xcarchive" -derivedDataPath build/ddios-release \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="Apple Distribution" DEVELOPMENT_TEAM="$TEAM" \
  PROVISIONING_PROFILE_SPECIFIER="$PROFILE_NAME" \
  archive -quiet

cat > "$OUT/ExportOptions.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Apple Distribution</string>
  <key>provisioningProfiles</key><dict><key>$BUNDLE_ID</key><string>$PROFILE_NAME</string></dict>
  <key>uploadSymbols</key><true/>
</dict></plist>
EOF
xcodebuild -exportArchive -archivePath "$OUT/Relisten.xcarchive" -exportPath "$OUT" \
  -exportOptionsPlist "$OUT/ExportOptions.plist" -quiet
echo "ipa: $OUT/Relisten.ipa (build $BUILD_NUMBER)"

if [ "$ACTION" = upload ]; then
  : "${ASC_KEY_ID:?}" "${ASC_ISSUER:?}" "${API_PRIVATE_KEYS_DIR:?}"
  xcrun altool --upload-app -f "$OUT/Relisten.ipa" -t ios --apiKey "$ASC_KEY_ID" --apiIssuer "$ASC_ISSUER"
fi
