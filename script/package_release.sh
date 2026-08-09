#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.1.0}"
DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="$ROOT_DIR/build/package"
PAYLOAD_DIR="$STAGE_DIR/payload"
SCRIPTS_DIR="$STAGE_DIR/scripts"
SUPPORT_DIR="$PAYLOAD_DIR/Library/Application Support/QuickTimePlayerPlus"

cd "$ROOT_DIR"
make all

mkdir -p "$DIST_DIR" "$SUPPORT_DIR/PlugIns" "$SUPPORT_DIR/app-wrapper" "$SCRIPTS_DIR"
cp build/QuickTimePlayerPlus.dylib "$SUPPORT_DIR/QuickTimePlayerPlus.dylib"
cp build/QuickTimePlayerApplicationLauncher "$SUPPORT_DIR/QuickTimePlayerApplicationLauncher"
cp resources/QuickTimePlayerPlus-Info.plist "$SUPPORT_DIR/QuickTimePlayerPlus-Info.plist"
mkdir -p "$SUPPORT_DIR/Resources"
cp -R resources/en.lproj "$SUPPORT_DIR/Resources/en.lproj"
cp -R resources/ja.lproj "$SUPPORT_DIR/Resources/ja.lproj"
cp -R build/PlugIns/*.qtplugin "$SUPPORT_DIR/PlugIns/"
cp package/pkg-scripts/postinstall "$SCRIPTS_DIR/postinstall"
chmod +x "$SCRIPTS_DIR/postinstall"

PKG="$DIST_DIR/QuickTimePlayerPlus-$VERSION.pkg"
DMG_ROOT="$STAGE_DIR/dmg-root"
DMG="$DIST_DIR/QuickTimePlayerPlus-$VERSION.dmg"
ZIP="$DIST_DIR/QuickTimePlayerPlus-$VERSION-plugins.zip"

pkgbuild \
  --root "$PAYLOAD_DIR" \
  --scripts "$SCRIPTS_DIR" \
  --identifier "local.quicktimeplayerplus.installer" \
  --version "$VERSION" \
  --install-location "/" \
  "$PKG"

ditto -c -k --keepParent "$SUPPORT_DIR/PlugIns" "$ZIP"

mkdir -p "$DMG_ROOT"
cp "$PKG" "$DMG_ROOT/"
cp README.md "$DMG_ROOT/README.md"
hdiutil create -volname "QuickTimePlayerPlus $VERSION" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"

(
  cd "$DIST_DIR"
  shasum -a 256 "QuickTimePlayerPlus-$VERSION.pkg" "QuickTimePlayerPlus-$VERSION.dmg" "QuickTimePlayerPlus-$VERSION-plugins.zip" > SHA256SUMS.txt
)

ls -la "$DIST_DIR"
