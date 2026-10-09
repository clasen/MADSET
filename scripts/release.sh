#!/bin/zsh
# Builds Blendline, signs it with Developer ID and packs it in a notarized, stapled DMG.
# SIGN_IDENTITY: the Developer ID Application identity in the keychain.
# NOTARY_PROFILE: a profile saved with `xcrun notarytool store-credentials`.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_IDENTITY="Developer ID Application: Blyts LLC (69VZST7GND)"
NOTARY_PROFILE=madset-notary

./scripts/bundle.sh
APP=build/Blendline.app
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/Blendline-$VERSION.dmg"
STAGE=build/dmg

codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Blendline.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname Blendline -srcfolder "$STAGE" -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --sign "$SIGN_IDENTITY" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Released $DMG"
