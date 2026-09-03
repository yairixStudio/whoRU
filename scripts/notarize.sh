#!/bin/sh
# Sends a .pkg, .dmg or .zip to Apple's notary service and staples the
# ticket, so Gatekeeper opens it on any Mac without a warning.
#
#   scripts/notarize.sh build/whoRU-0.2.0.pkg
#
# Needs, once per Mac, a notarytool keychain profile (an app-specific
# password from appleid.apple.com, and the Team ID of the Developer ID):
#   xcrun notarytool store-credentials whoru-notary --apple-id you@example.com --team-id TEAMID
# NOTARY_PROFILE picks another profile name. Apple only notarizes files
# signed with Developer ID, so anything else is skipped with a note, and
# the calling script carries on.
set -eu

FILE="${1:?usage: scripts/notarize.sh <file.pkg|file.dmg|file.zip>}"
PROFILE="${NOTARY_PROFILE:-whoru-notary}"

if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
  echo "▸ notarization skipped: no keychain profile '${PROFILE}' (see scripts/notarize.sh)"
  exit 0
fi
case "$FILE" in
  *.pkg)
    if ! pkgutil --check-signature "$FILE" 2>/dev/null | grep -q "Developer ID Installer"; then
      echo "▸ notarization skipped: $FILE is not signed with Developer ID Installer"
      exit 0
    fi ;;
  *)
    if ! codesign -dv --verbose=2 "$FILE" 2>&1 | grep -q "Developer ID Application"; then
      echo "▸ notarization skipped: $FILE is not signed with Developer ID Application"
      exit 0
    fi ;;
esac

echo "▸ notarytool submit ($PROFILE)"
xcrun notarytool submit "$FILE" --keychain-profile "$PROFILE" --wait
echo "▸ stapler"
xcrun stapler staple "$FILE"
