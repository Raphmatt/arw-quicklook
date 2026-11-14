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
for EXT in ARWThumbnail ARWPreview; do
  APPEX="${INSTALL_DIR}/${APP_NAME}.app/Contents/PlugIns/${EXT}.appex"
  pluginkit -a "$APPEX" 2>/dev/null || true
  # Switch it on — the same as the toggle in System Settings › Login Items &
  # Extensions › Quick Look. A new bundle ID otherwise starts disabled and Quick
  # Look reports "Extension … not found".
  EXT_ID=$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "${APPEX}/Contents/Info.plist")
  pluginkit -e use -i "$EXT_ID" 2>/dev/null || echo "  (could not enable ${EXT} — turn it on in System Settings)"
done

echo "▶︎ Resetting Quick Look…"
qlmanage -r >/dev/null 2>&1 || true
qlmanage -r cache >/dev/null 2>&1 || true
killall -KILL quicklookd 2>/dev/null || true

echo "▶︎ Opening the app once (registers the extensions)…"
open "${INSTALL_DIR}/${APP_NAME}.app"

cat <<'EOF'

✓ Installed.

Both extensions are registered and enabled. In Finder, select a .ARW and
press Space.

If the preview doesn't appear, check that both are on (+ = enabled):
  pluginkit -mAvv | grep -i -A1 "arwquicklook\."
or turn on ARWThumbnail + ARWPreview in
  System Settings › General › Login Items & Extensions › Quick Look
EOF
pluginkit -mAvv 2>/dev/null | grep -i "arwquicklook\." || true
