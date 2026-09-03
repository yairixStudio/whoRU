#!/bin/sh
# Builds everything a release needs and leaves it in one folder, ready to
# upload to GitHub and to link from the download page.
#
#   scripts/make-release.sh 0.2.0     → build/whoRU-0.2.0-release/
#                                          whoRU-0.2.0.pkg
#                                          whoRU-0.2.0.dmg
#                                          SHA256SUMS.txt
#
# This is the only place a release version is written down: it is exported so
# build-app.sh, make-pkg.sh and make-dmg.sh all stamp the same number.
#
# Order matters. Apple's notary service returns a ticket, and `stapler` writes
# that ticket into the file, so a checksum taken before stapling does not match
# the file people download. Everything is signed, notarized and stapled first;
# the checksums are the last thing this script does, and it verifies them again
# before it finishes. For a tool whose whole job is telling people whether a
# file is what it claims to be, a published checksum that does not match is the
# one mistake that must never ship.
#
# The release folder is only written when the artefacts really are signed by
# Developer ID and carry a notarization ticket. Set ALLOW_UNSIGNED=1 to
# assemble one anyway, for a local test build that will not leave this Mac.
set -eu

cd "$(dirname "$0")/.."
VERSION="${1:-${VERSION:-0.2.0}}"
export VERSION

APP="build/whoRU.app"
PKG="build/whoRU-$VERSION.pkg"
DMG="build/whoRU-$VERSION.dmg"
OUT="build/whoRU-$VERSION-release"

echo "▸ whoRU $VERSION"
rm -rf "$APP" "$PKG" "$DMG" "$OUT"
scripts/build-app.sh
scripts/make-pkg.sh
scripts/make-dmg.sh

echo
echo "▸ checking what is about to be published"
FAILED=""
# Each check runs as an `if` condition, where a failure is an answer rather
# than the end of the script.
ok()  { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; FAILED="yes"; }

if codesign -dv --verbose=2 "$APP" 2>&1 | grep -q "Developer ID Application"
then ok "app signed with Developer ID Application"
else bad "app signed with Developer ID Application"; fi

if pkgutil --check-signature "$PKG" 2>/dev/null | grep -q "Developer ID Installer"
then ok "package signed with Developer ID Installer"
else bad "package signed with Developer ID Installer"; fi

if xcrun stapler validate "$PKG" >/dev/null 2>&1
then ok "package notarized and stapled"
else bad "package notarized and stapled"; fi

if xcrun stapler validate "$DMG" >/dev/null 2>&1
then ok "disk image notarized and stapled"
else bad "disk image notarized and stapled"; fi

# What Gatekeeper itself says, which is what the person downloading will see.
if spctl --assess --type install "$PKG" >/dev/null 2>&1
then ok "Gatekeeper accepts the package"
else bad "Gatekeeper accepts the package"; fi

if spctl --assess --type execute "$APP" >/dev/null 2>&1
then ok "Gatekeeper accepts the app"
else bad "Gatekeeper accepts the app"; fi

if [ -n "$FAILED" ]; then
  echo
  echo "Not writing $OUT: the checks above have to pass first."
  echo "See scripts/notarize.sh, or set ALLOW_UNSIGNED=1 for a local test build."
  [ -n "${ALLOW_UNSIGNED:-}" ] || exit 1
  echo "ALLOW_UNSIGNED is set; carrying on. Do not publish this."
fi

echo
echo "▸ assembling $OUT"
mkdir -p "$OUT"
cp "$PKG" "$DMG" "$OUT/"
# Names in the file stay relative, so `shasum -c SHA256SUMS.txt` works for
# anyone who downloads the two files into the same folder.
( cd "$OUT" && shasum -a 256 "whoRU-$VERSION.dmg" "whoRU-$VERSION.pkg" > SHA256SUMS.txt )
( cd "$OUT" && shasum -a 256 -c SHA256SUMS.txt )

echo
ls -la "$OUT"
cat "$OUT/SHA256SUMS.txt"
echo
echo "✓ $OUT"
echo
echo "Publish it:"
echo "  git tag -a v$VERSION -m 'whoRU $VERSION' && git push origin v$VERSION"
echo "  gh release create v$VERSION $OUT/* --title 'whoRU $VERSION' --notes-file <notes>"
