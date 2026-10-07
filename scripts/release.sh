#!/bin/zsh
# Builds MADSET, signs it with Developer ID and packs it in a notarized, stapled DMG.
# MADSET_SIGN_IDENTITY: the "Developer ID Application: …" identity in the keychain.
# MADSET_NOTARY_PROFILE: a profile saved with `xcrun notarytool store-credentials`.
set -euo pipefail
cd "$(dirname "$0")/.."

: "${MADSET_SIGN_IDENTITY:?set MADSET_SIGN_IDENTITY to the Developer ID Application identity}"
: "${MADSET_NOTARY_PROFILE:?set MADSET_NOTARY_PROFILE to the notarytool keychain profile}"

./scripts/bundle.sh
APP=build/MADSET.app
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
DMG="build/MADSET-$VERSION.dmg"
STAGE=build/dmg

codesign --force --options runtime --timestamp --sign "$MADSET_SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"

rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/MADSET.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname MADSET -srcfolder "$STAGE" -format UDZO "$DMG"
rm -rf "$STAGE"
codesign --sign "$MADSET_SIGN_IDENTITY" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile "$MADSET_NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
echo "Released $DMG"
