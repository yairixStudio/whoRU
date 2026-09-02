#!/bin/sh
# Builds the one file for a download page: an installer package that puts
# whoRU.app into /Applications, the `whoru` command-line tool on the PATH,
# and opens the app when it is done so first-run setup starts at once.
#
#   scripts/make-pkg.sh                 → build/whoRU-<version>.pkg
#   VERSION=0.2.0 scripts/make-pkg.sh
#
# Signing and notarization happen when the Mac has what they need, and are
# skipped with a note otherwise:
#   - the app is signed by scripts/build-app.sh with a "Developer ID
#     Application" certificate when one is in the Keychain;
#   - the package is signed with a "Developer ID Installer" certificate;
#   - scripts/notarize.sh sends the package to Apple and staples the ticket
#     when a notarytool keychain profile exists (default name whoru-notary).
# Without Developer ID, the package installs fine here but Gatekeeper on
# other Macs refuses it; see the summary this script prints at the end.
set -eu

cd "$(dirname "$0")/.."
VERSION="${VERSION:-0.1.0}"
APP="build/whoRU.app"
STAGE="build/pkg"
PKG="build/whoRU-$VERSION.pkg"
IDENTIFIER="com.yairixstudio.whoru"

[ -d "$APP" ] || VERSION="$VERSION" scripts/build-app.sh
if [ ! -x "$APP/Contents/MacOS/whoru-cli" ]; then
  echo "$APP has no command-line tool inside; rebuilding"
  VERSION="$VERSION" scripts/build-app.sh
fi

echo "▸ staging"
rm -rf "$STAGE" "$PKG"
mkdir -p "$STAGE/root/Applications" "$STAGE/scripts"
# Files only: extended attributes a launched or copied app picks up
# (provenance, quarantine) must not travel in the payload.
ditto --norsrc --noextattr --noqtn "$APP" "$STAGE/root/Applications/whoRU.app"
codesign --verify --strict "$STAGE/root/Applications/whoRU.app"
cp pkg/scripts/preinstall pkg/scripts/postinstall "$STAGE/scripts/"
chmod 755 "$STAGE/scripts/preinstall" "$STAGE/scripts/postinstall"

# The app must land in /Applications even if an older copy sits elsewhere;
# the default is to "relocate" onto whatever copy Spotlight finds first.
pkgbuild --analyze --root "$STAGE/root" "$STAGE/components.plist" >/dev/null
/usr/libexec/PlistBuddy -c "Set :0:BundleIsRelocatable false" "$STAGE/components.plist" 2>/dev/null || true

echo "▸ pkgbuild"
# Files written from some shells carry a system attribute (com.apple.provenance)
# that nothing can strip; pkgbuild reports it as "write: Permission denied"
# and carries on. Harmless in the payload, so only that line is dropped.
if ! pkgbuild --root "$STAGE/root" --install-location / --identifier "$IDENTIFIER" --version "$VERSION" \
  --component-plist "$STAGE/components.plist" --scripts "$STAGE/scripts" "$STAGE/whoRU-component.pkg" >/dev/null 2>"$STAGE/pkgbuild.err"; then
  cat "$STAGE/pkgbuild.err"
  exit 1
fi
grep -v "^write: Permission denied" "$STAGE/pkgbuild.err" || true

ARCHS="$(lipo -archs "$APP/Contents/MacOS/whoRU" | tr ' ' ',')"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@ARCHS@/$ARCHS/g" pkg/distribution.xml > "$STAGE/distribution.xml"

INSTALLER_IDENTITY="$(security find-identity -v 2>/dev/null | grep '"Developer ID Installer: ' | head -1 | awk '{print $2}')"
echo "▸ productbuild"
if [ -n "${INSTALLER_IDENTITY:-}" ]; then
  productbuild --distribution "$STAGE/distribution.xml" --resources pkg/resources --package-path "$STAGE" \
    --sign "$INSTALLER_IDENTITY" --timestamp "$PKG" >/dev/null
else
  productbuild --distribution "$STAGE/distribution.xml" --resources pkg/resources --package-path "$STAGE" "$PKG" >/dev/null
fi
rm -rf "$STAGE"

scripts/notarize.sh "$PKG"

echo
ls -la "$PKG"
echo "✓ $PKG ($ARCHS)"
echo
echo "Ready for other Macs?"
if codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "Developer ID Application"; then
  echo "  ✓ app signed with Developer ID Application"
else
  echo "  ✗ app not signed with Developer ID Application (Gatekeeper will refuse it elsewhere)"
fi
if pkgutil --check-signature "$PKG" 2>/dev/null | grep -q "Developer ID Installer"; then
  echo "  ✓ package signed with Developer ID Installer"
else
  echo "  ✗ package unsigned: no “Developer ID Installer” certificate in the Keychain"
fi
if xcrun stapler validate "$PKG" >/dev/null 2>&1; then
  echo "  ✓ notarized and stapled"
else
  echo "  ✗ not notarized (see scripts/notarize.sh)"
fi
