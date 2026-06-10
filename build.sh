#!/bin/bash
# Build, ad-hoc sign, install to /Applications, and register the Quick Look extensions.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="ARWQuickLook"
INSTALL_DIR="/Applications"

echo "▶︎ Generating Xcode project (xcodegen)…"
command -v xcodegen >/dev/null || { echo "✗ xcodegen missing — run: brew install xcodegen"; exit 1; }
xcodegen generate

echo "▶︎ Building Release (ad-hoc signed)…"
xcodebuild \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${APP_NAME}" \
  -configuration Release \
  -derivedDataPath build \
  -quiet \
  build

BUILT="build/Build/Products/Release/${APP_NAME}.app"
[ -d "$BUILT" ] || { echo "✗ Build product not found at $BUILT"; exit 1; }

echo "▶︎ Installing to ${INSTALL_DIR}…"
rm -rf "${INSTALL_DIR}/${APP_NAME}.app"
cp -R "$BUILT" "${INSTALL_DIR}/"

echo "▶︎ Registering with Launch Services + pluginkit…"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"
# Unregister the build product first — otherwise it shows up as a duplicate
# app entry in System Settings › Login Items & Extensions.
"$LSREGISTER" -u "$(pwd)/${BUILT}" 2>/dev/null || true
"$LSREGISTER" -f "${INSTALL_DIR}/${APP_NAME}.app"
pluginkit -a "${INSTALL_DIR}/${APP_NAME}.app/Contents/PlugIns/ARWThumbnail.appex" 2>/dev/null || true
pluginkit -a "${INSTALL_DIR}/${APP_NAME}.app/Contents/PlugIns/ARWPreview.appex" 2>/dev/null || true

echo "▶︎ Resetting Quick Look…"
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true
killall -KILL quicklookd 2>/dev/null || true

echo "▶︎ Opening the app once (registers the extensions)…"
open "${INSTALL_DIR}/${APP_NAME}.app"

cat <<'EOF'

✓ Installed.

Next:
  1. Enable both extensions:
     System Settings › General › Login Items & Extensions › Quick Look
     (toggle ARWThumbnail + ARWPreview ON)
  2. In Finder, select a .ARW and press Space.

Verify which generator handles ARW:
  pluginkit -m -p com.apple.quicklook.preview   | grep -i arw
  qlmanage -p "/path/to/photo.ARW"
EOF
