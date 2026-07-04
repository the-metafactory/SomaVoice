#!/usr/bin/env bash
# Build a real SomaVoice.app bundle. A bundle (with Info.plist usage strings) is
# required for macOS to grant microphone + speech-recognition permission -- a
# bare `swift run` binary cannot request them reliably.
set -euo pipefail
cd "$(dirname "$0")"

APP="SomaVoice.app"
echo "[1/4] building release..."
swift build -c release

echo "[2/4] assembling ${APP}..."
rm -rf "${APP}"
mkdir -p "${APP}/Contents/MacOS"
cp ".build/release/SomaVoice" "${APP}/Contents/MacOS/SomaVoice"

echo "[3/4] writing Info.plist..."
cat > "${APP}/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>SomaVoice</string>
  <key>CFBundleDisplayName</key><string>SomaVoice</string>
  <key>CFBundleIdentifier</key><string>ai.metafactory.somavoice</string>
  <key>CFBundleVersion</key><string>0.1</string>
  <key>CFBundleShortVersionString</key><string>0.1</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleExecutable</key><string>SomaVoice</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key>
  <string>SomaVoice listens to your microphone so you can talk to your assistants.</string>
  <key>NSSpeechRecognitionUsageDescription</key>
  <string>SomaVoice transcribes your speech on-device to send to your assistant.</string>
</dict>
</plist>
PLIST

echo "[4/4] codesigning (stable dev identity)..."
# Stable identity so macOS TCC grants (mic, speech, screen) survive rebuilds.
# Ad-hoc signing (--sign -) changes the designated requirement every build and
# silently revokes those grants. SIGN_IDENTITY can override the default cert.
SIGN_IDENTITY="${SIGN_IDENTITY:-MetaFactoryDev}"
codesign --force --deep --sign "${SIGN_IDENTITY}" "${APP}"

echo "OK: built ${APP}"
echo "run:  open ${APP}   (waveform icon appears in the menu bar)"
