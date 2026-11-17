#!/bin/bash
# Сборка и установка NotchApp.
#   ./build_app.sh               — собрать, установить в /Applications и запустить
#   ./build_app.sh --no-install  — только собрать NotchApp.app в папке проекта
set -e
cd "$(dirname "$0")"

INSTALL=1
[ "${1:-}" = "--no-install" ] && INSTALL=0

SIGN_NAME="NotchApp Local Signing"
LABEL="local.notchapp"
APP="NotchApp.app"
DEST="/Applications/NotchApp.app"
AGENT="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "→ Сборка…"
# --disable-sandbox: SwiftPM не может запустить sandbox-exec внутри внешней песочницы
swift build --disable-sandbox -c release

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/NotchApp "$APP/Contents/MacOS/NotchApp"

echo "→ Помощник «Сейчас играет» (запускается внутри /usr/bin/perl)…"
clang -dynamiclib -fobjc-arc -O2 -mmacosx-version-min=15.0 -framework Foundation \
    -o "$APP/Contents/Resources/libnotchmedia.dylib" Helper/NowPlayingHelper.m
cp Helper/LICENSE-cyclop.txt "$APP/Contents/Resources/"

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
    <key>CFBundleShortVersionString</key><string>1.1</string>
    <key>CFBundleVersion</key><string>2</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>LSUIElement</key><true/>
    <key>NSCameraUsageDescription</key><string>Показывать тебя в круглом «зеркале» под чёлкой.</string>
    <key>NSMicrophoneUsageDescription</key><string>Записать голос, чтобы превратить его в текст.</string>
    <key>NSSpeechRecognitionUsageDescription</key><string>Превращать голос, аудио и видео в текст.</string>
    <key>NSAppleEventsUsageDescription</key><string>Показывать и переключать музыку и видео в плеерах и браузерах.</string>
</dict>
</plist>
PLIST

# Подпись. С постоянным сертификатом (scripts/setup_signing.sh) разрешения macOS
# переживают пересборку. Без него — временная ad-hoc подпись, и после каждой
# сборки macOS заново спрашивает «Универсальный доступ», автоматизацию и т.д.
ID=$(security find-identity -p codesigning 2>/dev/null | awk -v n="\"$SIGN_NAME\"" 'index($0, n) {print $2; exit}')
sign() {
    codesign --force --sign "$1" "$APP/Contents/Resources/libnotchmedia.dylib" &&
    codesign --force --sign "$1" "$APP"
}
if [ -n "$ID" ] && sign "$ID"; then
    echo "→ Подписано постоянным сертификатом «${SIGN_NAME}» — разрешения сохранятся"
else
    sign -
    echo "⚠︎ Подписано ad-hoc. Один раз запусти ./scripts/setup_signing.sh —"
    echo "  тогда разрешения перестанут слетать после сборки."
fi

if [ "$INSTALL" = 0 ]; then
    echo "✓ Собрано: $(pwd)/$APP"
    exit 0
fi

echo "→ Установка в /Applications…"
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -x NotchApp 2>/dev/null || true
sleep 0.6
rm -rf "$DEST"
ditto "$APP" "$DEST"

# Автозапуск при входе и перезапуск после сбоя. Обычный «Выйти» (код 0) не перезапускает.
mkdir -p "$HOME/Library/LaunchAgents"
cat > "$AGENT" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key>
    <array><string>$DEST/Contents/MacOS/NotchApp</string></array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key>
    <dict><key>SuccessfulExit</key><false/></dict>
    <key>ThrottleInterval</key><integer>10</integer>
    <key>ProcessType</key><string>Interactive</string>
    <key>LimitLoadToSessionType</key><string>Aqua</string>
</dict>
</plist>
PLIST
launchctl bootstrap "gui/$(id -u)" "$AGENT"
sleep 1.5
if pgrep -x NotchApp >/dev/null; then
    echo "✓ Установлено и запущено: $DEST"
else
    echo "⚠︎ launchd не запустил приложение, открываю вручную"
    open "$DEST"
fi
