#!/bin/bash
# Збирає universal SvitloBar.app (arm64 + x86_64), пакує dist/SvitloBar.zip і встановлює в ~/Applications.
# Версія: змінна VERSION (так робить CI) або файл VERSION. SKIP_INSTALL=1 — лише зібрати.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"
BUILD_DIR="build"
APP="$BUILD_DIR/SvitloBar.app"
INSTALL_DIR="$HOME/Applications/SvitloBar.app"

rm -rf "$BUILD_DIR" dist
mkdir -p "$APP/Contents/MacOS" dist

for arch in arm64 x86_64; do
    swiftc -O -target "$arch-apple-macos13.0" -o "$BUILD_DIR/SvitloBar-$arch" Sources/main.swift
done
lipo -create -output "$APP/Contents/MacOS/SvitloBar" "$BUILD_DIR/SvitloBar-arm64" "$BUILD_DIR/SvitloBar-x86_64"

cp Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"

ditto -c -k --keepParent "$APP" dist/SvitloBar.zip

if [ "${SKIP_INSTALL:-0}" = "1" ]; then
    echo "Зібрано SvitloBar $VERSION → dist/SvitloBar.zip"
    exit 0
fi

# Якщо додаток запущений — зупинити перед заміною
pkill -x SvitloBar 2>/dev/null || true
rm -rf "$INSTALL_DIR"
ditto "$APP" "$INSTALL_DIR"

echo "Зібрано SvitloBar $VERSION"
echo "Архів для релізу: dist/SvitloBar.zip"
echo "Запуск: open \"$INSTALL_DIR\""
