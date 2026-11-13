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
  <key>CFBundleShortVersionString</key><string>1.1</string>
  <key>CFBundleVersion</key><string>2</string>
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

# Sign with the local "Meet for Me Local Signing" certificate when it exists, so macOS keeps
# the app's permissions (microphone, audio recording, Documents) across rebuilds. Without it,
# fall back to ad-hoc signing (each build then counts as a new app for permissions).
IDENTITY="Meet for Me Local Signing"
if security find-identity -p codesigning 2>/dev/null | grep -q "\"$IDENTITY\""; then
  codesign --force --sign "$IDENTITY" "$APP"
  echo "Signed with: $IDENTITY"
else
  codesign --force --sign - "$APP"
  echo "Signed ad-hoc (no '$IDENTITY' certificate found; see README to create one)"
fi
echo "Built: $(pwd)/$APP"
