#!/bin/bash
# Сборка NotchApp.app (нужен Xcode или Command Line Tools: xcode-select --install)
set -e
cd "$(dirname "$0")"

echo "→ Сборка…"
# --disable-sandbox: SwiftPM не может запустить sandbox-exec внутри внешней песочницы
swift build --disable-sandbox -c release

APP="NotchApp.app"
pkill -x NotchApp 2>/dev/null || true
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp .build/release/NotchApp "$APP/Contents/MacOS/NotchApp"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>local.notchapp</string>
    <key>CFBundleName</key><string>NotchApp</string>
    <key>CFBundleDisplayName</key><string>Чёлка</string>
    <key>CFBundleExecutable</key><string>NotchApp</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSCalendarsFullAccessUsageDescription</key><string>Показывать твои события в календаре чёлки.</string>
    <key>NSCalendarsUsageDescription</key><string>Показывать твои события в календаре чёлки.</string>
    <key>NSMicrophoneUsageDescription</key><string>Записать голос, чтобы превратить его в текст.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Превращать голос, аудио и видео в текст.</string>
    <key>NSAppleEventsUsageDescription</key><string>Управлять музыкой в Music и Spotify.</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign - "$APP"
echo "✓ Готово: $(pwd)/$APP"
open "$APP"
