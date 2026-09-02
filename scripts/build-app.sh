#!/bin/sh
# Builds whoRU.app from the Swift package. No Xcode project needed.
#
#   scripts/build-app.sh            release build, ad-hoc signed → build/whoRU.app
#   CONFIG=debug scripts/build-app.sh
#   CODESIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh
set -eu

cd "$(dirname "$0")/.."
CONFIG="${CONFIG:-release}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
IDENTITY="${CODESIGN_IDENTITY:--}"
BUNDLE_ID="com.yairixstudio.whoru"
APP="build/whoRU.app"

echo "▸ swift build -c $CONFIG"
swift build -c "$CONFIG" --product whoru 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" || true
BIN=".build/$CONFIG/whoru"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

echo "▸ assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/whoRU"
# SwiftPM resource bundles, if any target declares resources.
for bundle in ".build/$CONFIG"/whoRU_*.bundle; do
  [ -d "$bundle" ] && cp -R "$bundle" "$APP/Contents/Resources/"
done

if [ ! -f build/AppIcon.icns ] && command -v swift >/dev/null; then
  echo "▸ rendering icon"
  swift scripts/make-icon.swift build/AppIcon.icns >/dev/null 2>&1 || true
fi
[ -f build/AppIcon.icns ] && cp build/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>whoRU</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>whoRU</string>
  <key>CFBundleDisplayName</key><string>whoRU</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>26.0</string>
  <key>LSUIElement</key><true/>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>NSHumanReadableCopyright</key><string>© 2026 yairix. MIT License.</string>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>NSSupportsSuddenTermination</key><false/>
  <key>NSDownloadsFolderUsageDescription</key><string>whoRU touches your Downloads folder only when you press “Try it now”, to show you what a permission dialog with a companion looks like.</string>
</dict>
</plist>
EOF
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "▸ codesign ($IDENTITY)"
if [ "$IDENTITY" = "-" ]; then
  codesign --force --sign - --options runtime --timestamp=none "$APP"
else
  codesign --force --sign "$IDENTITY" --options runtime --timestamp "$APP"
fi
codesign --verify --strict "$APP" && echo "✓ $APP"
