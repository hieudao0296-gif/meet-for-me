#!/bin/bash
# Builds "Meet for Me.app" from MeetForMe.swift (needs only the Command Line Tools).
set -euo pipefail
cd "$(dirname "$0")"

APP="build/Meet for Me.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -parse-as-library -O -swift-version 5 \
  -target arm64-apple-macos14.4 \
  MeetForMe.swift -o "$APP/Contents/MacOS/MeetForMe"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Meet for Me</string>
  <key>CFBundleDisplayName</key><string>Meet for Me</string>
  <key>CFBundleIdentifier</key><string>local.meetinglistener</string>
  <key>CFBundleExecutable</key><string>MeetForMe</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>LSMinimumSystemVersion</key><string>14.4</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>Meet for Me reads meeting audio from BlackHole to transcribe it on this Mac.</string>
  <key>NSAudioCaptureUsageDescription</key>
  <string>Meet for Me records the audio of your meeting apps (Zoom, Teams, your browser) to transcribe it on this Mac.</string>
</dict>
</plist>
PLIST

[ -f AppIcon.icns ] && cp AppIcon.icns "$APP/Contents/Resources/"

codesign --force --sign - "$APP"
echo "Built: $(pwd)/$APP"
