#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release "$@"
binary_directory="$(swift build -c release "$@" --show-bin-path)"
app="dist/Quota Bar.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Resources/AppIcon.icns "$app/Contents/Resources/AppIcon.icns"
cp "$binary_directory/QuotaBar" "$app/Contents/MacOS/QuotaBar"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.decryptu.quota-bar</string>
    <key>CFBundleName</key><string>Quota Bar</string>
    <key>CFBundleExecutable</key><string>QuotaBar</string>
    <key>CFBundleIconFile</key><string>AppIcon.icns</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.1.2</string>
    <key>CFBundleVersion</key><string>4</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSUIElement</key><true/>
</dict>
</plist>
PLIST
codesign --force --sign - "$app"
