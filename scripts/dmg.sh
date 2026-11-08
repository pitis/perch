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
# build.sh falls back to ad hoc, and another team's certificate would change the app's identity: either
# way every user's permissions reset on update, so a release must carry this team's signature.
req='anchor apple generic and certificate leaf[subject.OU] = "95KQ82C586"'
codesign --verify --strict -R="$req" dist/Perch.app || { echo "✗ dist/Perch.app isn't signed by team 95KQ82C586" >&2; exit 1; }
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
ditto dist/Perch.app "$stage/Perch.app"
ln -s /Applications "$stage/Applications"
dmg=dist/Perch-$version.dmg
rm -f "$dmg"
hdiutil create -quiet -volname "Perch $version" -srcfolder "$stage" -fs HFS+ -format UDZO "$dmg"
[ "$(git rev-parse HEAD)" = "$(git rev-parse -q --verify origin/main)" ] ||
  echo "• built from $(git rev-parse --short HEAD), not origin/main: fine for a test, not for a release" >&2
echo "✓ $dmg ($(git rev-parse --short HEAD))"
