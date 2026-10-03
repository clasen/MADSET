#!/bin/zsh
# Builds MADSET in release mode and wraps it in build/MADSET.app.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product MADSET
BIN_DIR="$(swift build -c release --show-bin-path)"
APP=build/MADSET.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MADSET" "$APP/Contents/MacOS/MADSET"
cp -R Localization/*.lproj "$APP/Contents/Resources/"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MADSET</string>
    <key>CFBundleIdentifier</key><string>com.martinclasen.madset</string>
    <key>CFBundleName</key><string>MADSET</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.2</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleLocalizations</key><array><string>en</string><string>es</string></array>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>MADSET Set</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Owner</string>
            <key>LSItemContentTypes</key><array><string>com.martinclasen.madset.set</string></array>
        </dict>
    </array>
    <key>UTExportedTypeDeclarations</key>
    <array>
        <dict>
            <key>UTTypeIdentifier</key><string>com.martinclasen.madset.set</string>
            <key>UTTypeDescription</key><string>MADSET Set</string>
            <key>UTTypeConformsTo</key><array><string>public.json</string></array>
            <key>UTTypeTagSpecification</key>
            <dict><key>public.filename-extension</key><array><string>madset</string></array></dict>
        </dict>
    </array>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
