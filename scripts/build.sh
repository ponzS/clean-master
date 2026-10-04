#!/bin/zsh
set -euo pipefail
PROJECT_ROOT="$(cd -- "$(dirname -- "$0")/.." && pwd)"
cd "$PROJECT_ROOT"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
APP_PATH="$PROJECT_ROOT/dist/clean-master.app"
mkdir -p "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"
cp "$BIN_DIR/clean-master" "$APP_PATH/Contents/MacOS/clean-master"
cp Resources/Info.plist "$APP_PATH/Contents/Info.plist"
cp Resources/PrivacyInfo.xcprivacy "$APP_PATH/Contents/Resources/PrivacyInfo.xcprivacy"
swift scripts/make-icon.swift .build/AppIcon.iconset
iconutil -c icns .build/AppIcon.iconset -o "$APP_PATH/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP_PATH"
printf '\n已构建：%s\n' "$APP_PATH"
