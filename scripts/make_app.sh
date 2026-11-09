#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG=${1:-release}
if [ "$CONFIG" = "release" ]; then
    swift build -c release
    BIN=".build/release/WakeMacApp"
else
    swift build
    BIN=".build/debug/WakeMacApp"
fi
APP="build/WakeMac.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/WakeMac"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>WakeMac</string>
    <key>CFBundleIdentifier</key><string>com.local.wakemac</string>
    <key>CFBundleExecutable</key><string>WakeMac</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>0.1.0</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSMicrophoneUsageDescription</key><string>Wake Mac uses the microphone only while actively listening for your requests after activation (Hi Mac, hotkey, or push-to-talk).</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Wake Mac transcribes your spoken requests locally (on-device recognition required; no cloud fallback).</string>
    <key>NSAppleEventsUsageDescription</key><string>Wake Mac sends predefined Apple Events (fixed templates) to perform requested actions like opening a new tab.</string>
    <key>NSAppleScriptEnabled</key><true/>
</dict>
</plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
codesign --force --sign - "$APP" 2>/dev/null || true
echo "Built $APP"
