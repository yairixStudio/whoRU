#!/bin/sh
# Packages build/whoRU.app into a drag-to-Applications disk image.
#
#   scripts/make-dmg.sh                 → build/whoRU-<version>.dmg
#   VERSION=0.2.0 scripts/make-dmg.sh
#
# Builds the app first if it is missing. The image is signed with the same
# identity as the app when one is available; notarization needs a Developer ID
# and is a separate step (see docs/DESIGN.md §11).
set -eu

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
APP="build/whoRU.app"
STAGE="build/dmg"
DMG="build/whoRU-$VERSION.dmg"

[ -d "$APP" ] || VERSION="$VERSION" scripts/build-app.sh

echo "▸ staging"
rm -rf "$STAGE" "$DMG"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
cat > "$STAGE/.background-readme.txt" <<EOF
whoRU $VERSION — drag whoRU to the Applications folder, then open it.
First launch asks for the Accessibility permission (it only reads the text of permission dialogs).
https://github.com/yairixStudio/whoRU
EOF

echo "▸ hdiutil"
hdiutil create -volname "whoRU $VERSION" -srcfolder "$STAGE" -ov -format UDZO -quiet "$DMG"

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | grep -E '"(Developer ID Application|Apple Development): ' | head -1 | awk '{print $2}')"
if [ -n "${IDENTITY:-}" ]; then
  echo "▸ codesign dmg ($IDENTITY)"
  codesign --force --sign "$IDENTITY" "$DMG"
fi

rm -rf "$STAGE"
scripts/notarize.sh "$DMG"
ls -la "$DMG"
echo "✓ $DMG"
