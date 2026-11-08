#!/usr/bin/env bash
# Builds dist/Perch-<version>.dmg for a release (make dmg): a release build of Perch.app next to a link
# to /Applications, to drag it across. <version> is CFBundleShortVersionString in scripts/Info.plist.
# The app is signed like every build (scripts/build.sh) but not notarized, since that needs a paid
# Developer ID, so a downloaded copy opens the first time through Open Anyway in System Settings.
set -euo pipefail
cd "$(dirname "$0")/.."
[ -z "$(git status --porcelain)" ] || { echo "✗ uncommitted changes: a release is built from a commit" >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' scripts/Info.plist)
scripts/build.sh
codesign --verify --strict dist/Perch.app
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto dist/Perch.app "$stage/Perch.app"
ln -s /Applications "$stage/Applications"
dmg=dist/Perch-$version.dmg
rm -f "$dmg"
hdiutil create -quiet -volname "Perch $version" -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"
echo "✓ $dmg ($(git rev-parse --short HEAD))"
