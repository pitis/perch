#!/usr/bin/env bash
# Rebuilds scripts/AppIcon.icns and the README's docs/images/icon.png from the bird drawn in
# Sources/Perch/Views/AppMark.swift (make icon). Run it after changing the drawing, and commit both.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
swift build -q --product Perch
"$(swift build --show-bin-path)/Perch" --snapshot "$tmp/shots"
art=$tmp/shots/app-icon.png
[ -s "$art" ] || { echo "✗ --snapshot didn't write $art" >&2; exit 1; }
[ "$(sips -g pixelWidth "$art" | awk '/pixelWidth/{print $2}')" = 1024 ] || { echo "✗ $art isn't 1024 pixels wide" >&2; exit 1; }
mkdir "$tmp/AppIcon.iconset"
for s in 16 32 128 256 512; do
  sips -z $s $s "$art" --out "$tmp/AppIcon.iconset/icon_${s}x${s}.png" >/dev/null
  sips -z $((s * 2)) $((s * 2)) "$art" --out "$tmp/AppIcon.iconset/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$tmp/AppIcon.iconset" -o scripts/AppIcon.icns
sips -z 256 256 "$art" --out docs/images/icon.png >/dev/null
echo "✓ scripts/AppIcon.icns, docs/images/icon.png"
