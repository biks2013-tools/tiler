#!/bin/zsh
# Build Tiler.app (release), sign it, and optionally install it.
#
#   TILER_SIGN_IDENTITY=<identity or SHA-1> scripts/build-app.sh [--install]
#
# The signing identity is required. Releases use the Developer ID Application
# certificate (pass its SHA-1, two identities share the name; see
# docs/design/release-runbook.md). A stable certificate keeps the app's code
# signature stable across rebuilds, so the Accessibility permission granted
# once keeps working. Ad-hoc signing would invalidate it on every build.
#
# VERSION names the release (tag v<VERSION>, cask version); BUILD must go up on
# every packaging run.
set -euo pipefail
cd "$(dirname "$0")/.."

if [[ -z "${TILER_SIGN_IDENTITY:-}" ]]; then
  echo "error: TILER_SIGN_IDENTITY is not set. Available identities:" >&2
  security find-identity -v -p codesigning >&2
  exit 1
fi

VERSION="0.8.2"
BUILD="19"
APP="build/Tiler.app"

swift build -c release --arch arm64 --arch x86_64
BIN="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/Tiler"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Tiler"
rm -rf build/AppIcon.iconset
swift scripts/make-icon.swift build/AppIcon.iconset
iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>com.giorgosmarinos.tiler</string>
  <key>CFBundleName</key><string>Tiler</string>
  <key>CFBundleDisplayName</key><string>Tiler</string>
  <key>CFBundleExecutable</key><string>Tiler</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>${VERSION}</string>
  <key>CFBundleVersion</key><string>${BUILD}</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 Giorgos Marinos</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSUIElement</key><true/>
  <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
PLIST

codesign --force --options runtime --timestamp \
  --identifier com.giorgosmarinos.tiler --sign "$TILER_SIGN_IDENTITY" "$APP"
codesign --verify --strict "$APP"
echo "built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x Tiler 2>/dev/null || true
  rm -rf /Applications/Tiler.app
  cp -R "$APP" /Applications/Tiler.app
  open /Applications/Tiler.app
  echo "installed /Applications/Tiler.app"
fi
