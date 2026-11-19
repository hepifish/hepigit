#!/bin/zsh
# Builds dist/Hepigit-<version>.dmg: the app plus an Applications shortcut, ready to share.
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VERSION:-$(cat VERSION)}"
export VERSION
./scripts/bundle.sh

STAGE="$(mktemp -d)/Hepigit"
mkdir -p "$STAGE"
cp -R dist/Hepigit.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/First launch.txt" <<TXT
Drag Hepigit into Applications.

The app isn't notarized by Apple, so the first time:
right-click Hepigit in Applications > Open > Open.
(Or in Terminal: xattr -dr com.apple.quarantine /Applications/Hepigit.app)

Needs macOS 15 or newer and git (installed with Xcode Command Line Tools).
TXT

DMG="dist/Hepigit-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "Hepigit" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov "$DMG" >/dev/null
codesign --force --sign - "$DMG" 2>/dev/null || true
echo "Built $DMG ($(du -h "$DMG" | cut -f1))"
