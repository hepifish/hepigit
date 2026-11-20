#!/bin/zsh
# Builds Hepigit.app (release) into dist/. Pass --install to copy it to /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-$(cat VERSION)}"
# GitHub repo the app checks for new releases (owner/name). Must be public.
UPDATE_REPO="${UPDATE_REPO:-hepifish/hepigit}"
APP="dist/Hepigit.app"

swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Hepigit"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Hepigit"
strip -x "$APP/Contents/MacOS/Hepigit" 2>/dev/null || true

ICONSET="$(mktemp -d)/Hepigit.iconset"
swift scripts/make-icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/Hepigit.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>Hepigit</string>
  <key>CFBundleDisplayName</key><string>Hepigit</string>
  <key>CFBundleIdentifier</key><string>app.hepigit</string>
  <key>CFBundleExecutable</key><string>Hepigit</string>
  <key>CFBundleIconFile</key><string>Hepigit</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${VERSION}</string>
  <key>LSMinimumSystemVersion</key><string>15.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDocumentTypes</key>
  <array><dict>
    <key>CFBundleTypeName</key><string>Folder</string>
    <key>CFBundleTypeRole</key><string>Viewer</string>
    <key>LSHandlerRank</key><string>Alternate</string>
    <key>LSItemContentTypes</key><array><string>public.folder</string></array>
  </dict></array>
  <key>HepigitUpdateRepo</key><string>${UPDATE_REPO}</string>
  <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
</dict>
</plist>
PLIST

# Ad-hoc signature: enough to run locally. Colleagues: right-click > Open the first time.
codesign --force --deep --sign - "$APP"

echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Hepigit 2>/dev/null || true
  rm -rf /Applications/Hepigit.app
  cp -R "$APP" /Applications/
  echo "Installed to /Applications/Hepigit.app"
fi
