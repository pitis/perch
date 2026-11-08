#!/bin/bash
# Builds dist/Perch.app. With --install, also replaces /Applications/Perch.app and launches it.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --product Perch

APP=dist/Perch.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$(swift build -c release --show-bin-path)/Perch" "$APP/Contents/MacOS/Perch"
cp scripts/Info.plist "$APP/Contents/Info.plist"
mkdir -p "$APP/Contents/Resources"
cp scripts/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

# A stable signature keeps macOS permissions across rebuilds. Ad-hoc signing would re-prompt every time.
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)
codesign --force --sign "${IDENTITY:--}" "$APP"
echo "Built $APP (signed with: ${IDENTITY:-ad-hoc})"

if [[ "${1:-}" == "--install" ]]; then
    pkill -x Perch 2>/dev/null || true
    sleep 0.5
    rm -rf /Applications/Perch.app
    cp -R "$APP" /Applications/Perch.app
    open /Applications/Perch.app
    echo "Installed and launched /Applications/Perch.app"
fi
