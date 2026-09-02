#!/bin/sh
# Puts the issued Developer ID certificates into the login keychain, paired
# with their private keys and named for whoRU, so build-app.sh, make-dmg.sh
# and make-pkg.sh pick them up by themselves.
#
#   scripts/import-developer-id.sh
#
# Expects, in .signing/ (gitignored, at the project root):
#   whoRU-developer-id-application.key   private key behind the request
#   whoRU-developer-id-installer.key
#   developerID_application.cer          issued at developer.apple.com from
#   developerID_installer.cer            .signing/*.certSigningRequest
#
# Each pair becomes one keychain identity: the certificate keeps Apple's
# name ("Developer ID Application: <team> (TEAMID)"); its private key is
# labelled "whoRU Developer ID Application" / "… Installer". Key files are
# shredded once the identity is in the keychain; the certificates stay.
set -eu

cd "$(dirname "$0")/.."
DIR=".signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
CA="$DIR/DeveloperIDG2CA.cer"

[ -f "$CA" ] || curl -sSfL -o "$CA" https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
if ! security find-certificate -c "Developer ID Certification Authority" "$KEYCHAIN" >/dev/null 2>&1; then
  echo "▸ installing Apple's Developer ID intermediate certificate"
  security import "$CA" -k "$KEYCHAIN"
fi
openssl x509 -inform der -in "$CA" -out "$DIR/DeveloperIDG2CA.pem"

import_pair() {
  kind="$1"; name="$2"; cer="$DIR/developerID_$kind.cer"; key="$DIR/whoRU-developer-id-$kind.key"
  if [ ! -f "$cer" ]; then echo "▸ $name: no $cer yet"; return 0; fi
  if security find-identity -v 2>/dev/null | grep -q "\"$name: "; then
    echo "▸ $name: already in the keychain"
    return 0
  fi
  [ -f "$key" ] || { echo "▸ $name: certificate found but no private key at $key"; return 1; }
  echo "▸ $name: importing as “whoRU ${name}”"
  openssl x509 -inform der -in "$cer" -out "$DIR/developerID_$kind.pem"
  # A PKCS#12 bundle is the one form `security import` accepts with a friendly
  # name; it must use the older ciphers, the keychain cannot read AES/SHA-256 ones.
  # The keychain names the private key after the file, so the file carries the name.
  p12="$DIR/whoRU $name.p12"
  openssl pkcs12 -export -name "whoRU $name" -inkey "$key" -in "$DIR/developerID_$kind.pem" \
    -certfile "$DIR/DeveloperIDG2CA.pem" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 -passout pass:whoRU -out "$p12"
  security import "$p12" -k "$KEYCHAIN" -P whoRU \
    -T /usr/bin/codesign -T /usr/bin/productbuild -T /usr/bin/pkgbuild -T /usr/bin/security
  rm -P "$p12" "$DIR/developerID_$kind.pem"
  if security find-identity -v 2>/dev/null | grep -q "\"$name: "; then
    rm -P "$key"
    echo "  ✓ identity ready; private key file shredded (it lives in the keychain now)"
  else
    echo "  ✗ identity not found after import"
    return 1
  fi
}

import_pair application "Developer ID Application"
import_pair installer "Developer ID Installer"
rm -f "$DIR/DeveloperIDG2CA.pem"

echo
echo "Signing identities now:"
security find-identity -v -p codesigning | grep "Developer ID Application" || echo "  ✗ no Developer ID Application identity"
security find-identity -v | grep "Developer ID Installer" || echo "  ✗ no Developer ID Installer identity"
echo
echo "Next: scripts/build-app.sh && scripts/make-pkg.sh"
echo "The first signing asks for the login keychain password once per tool; choose “Always Allow”,"
echo "or run: security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <login password> ~/Library/Keychains/login.keychain-db"
echo "Notarization needs, once, either an App Store Connect API key:"
echo "  xcrun notarytool store-credentials whoru-notary --key AuthKey_<ID>.p8 --key-id <ID> --issuer <Issuer ID>"
echo "or an app-specific password:"
echo "  xcrun notarytool store-credentials whoru-notary --apple-id <Apple ID> --team-id <Team ID>"
