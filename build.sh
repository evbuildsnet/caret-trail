#!/bin/zsh
# Builds build/CaretTrail.app. Run it with: open build/CaretTrail.app
set -euo pipefail
cd "$(dirname "$0")"
IDENTITY="${CODESIGN_IDENTITY:-Developer ID Application: EVGENII KABANOV (CPUP238G9V)}"

swift build -c release
APP=build/CaretTrail.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/CaretTrail "$APP/Contents/MacOS/CaretTrail"
cp Info.plist "$APP/Contents/Info.plist"
cp Assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign "$IDENTITY" --options runtime "$APP"
echo "Built $APP"
