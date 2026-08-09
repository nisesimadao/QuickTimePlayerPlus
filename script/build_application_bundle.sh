#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="${SOURCE_QUICKTIME_APP:-/System/Applications/QuickTime Player.app}"
APP_BUNDLE="$ROOT_DIR/dist/QuickTime Player+.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLUGIN_ROOT="$CONTENTS_DIR/PlugIns/QuickTimePlayerPlus"

cd "$ROOT_DIR"
make all

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Source QuickTime app not found: $SOURCE_APP" >&2
  exit 1
fi

if [[ -d "$APP_BUNDLE" ]]; then
  backup="$ROOT_DIR/dist/QuickTime Player+.$(date +%Y%m%d-%H%M%S).app"
  mv "$APP_BUNDLE" "$backup"
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$PLUGIN_ROOT"
cp resources/QuickTimePlayerPlus-Info.plist "$CONTENTS_DIR/Info.plist"
cp build/QuickTimePlayerApplicationLauncher "$MACOS_DIR/QuickTime Player+"
cp "$SOURCE_APP/Contents/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp -R "$SOURCE_APP" "$RESOURCES_DIR/QuickTime Player.app"
cp build/QuickTimePlayerPlus.dylib "$PLUGIN_ROOT/QuickTimePlayerPlus.dylib"
cp -R build/PlugIns/*.qtplugin "$PLUGIN_ROOT/"
chmod +x "$MACOS_DIR/QuickTime Player+"

codesign --force --deep --sign - "$RESOURCES_DIR/QuickTime Player.app"
codesign --force --deep --sign - "$APP_BUNDLE"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "$APP_BUNDLE"
