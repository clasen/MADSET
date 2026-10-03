#!/bin/zsh
# Builds MADSET in release mode and wraps it in build/MADSET.app.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product MADSET
BIN_DIR="$(swift build -c release --show-bin-path)"
APP=build/MADSET.app

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN_DIR/MADSET" "$APP/Contents/MacOS/MADSET"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>MADSET</string>
    <key>CFBundleIdentifier</key><string>com.martinclasen.madset</string>
    <key>CFBundleName</key><string>MADSET</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST
codesign --force --sign - "$APP"
echo "Built $APP"
