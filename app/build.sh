#!/bin/bash
# Builds StreamMate.app next to this script and opens it.
set -e
cd "$(dirname "$0")"
swift build -c release
APP="StreamMate.app"
mkdir -p "$APP/Contents/MacOS"
cp -f .build/release/StreamMate "$APP/Contents/MacOS/StreamMate"
mkdir -p "$APP/Contents/Resources"
cp -f AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.streammate.app</string>
    <key>CFBundleName</key><string>StreamMate</string>
    <key>CFBundleDisplayName</key><string>StreamMate</string>
    <key>CFBundleExecutable</key><string>StreamMate</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key><string>StreamMate finds your TV on the local network and streams your screen to it.</string>
</dict>
</plist>
PLIST
# Sign with a real signing identity if this Mac has one, so macOS keeps the
# Screen Recording permission across rebuilds. Otherwise sign ad hoc and clear
# the stale permission entry so macOS asks once, cleanly.
IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/"/{print $2; exit}')
if [ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" "$APP" 2>/dev/null; then
    echo "Signed with: $IDENTITY"
else
    codesign --force --sign - "$APP"
    tccutil reset ScreenCapture com.streammate.app >/dev/null 2>&1 || true
    echo "Signed ad hoc: macOS will ask for Screen Recording permission again."
fi
touch "$APP"
echo "Built $(pwd)/$APP"
open "$APP"
