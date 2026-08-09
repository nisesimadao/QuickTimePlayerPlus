#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="$ROOT_DIR/QuickTime Player Plus.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
EXECUTABLE_DIR="$CONTENTS_DIR/MacOS"
MAIN_EXECUTABLE="$EXECUTABLE_DIR/QuickTime Player"
REAL_EXECUTABLE="$EXECUTABLE_DIR/QuickTime Player.real"
PLUGIN_ROOT="$CONTENTS_DIR/PlugIns/QuickTimePlayerPlus"
INFO_PLIST="$CONTENTS_DIR/Info.plist"
WRAPPER_TEMPLATE="$ROOT_DIR/app-wrapper/QuickTime Player"

cd "$ROOT_DIR"
make all

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "App bundle not found: $APP_BUNDLE" >&2
  exit 1
fi

mkdir -p "$PLUGIN_ROOT"
cp "$ROOT_DIR/build/QuickTimePlayerPlus.dylib" "$PLUGIN_ROOT/QuickTimePlayerPlus.dylib"
rm -rf "$PLUGIN_ROOT/QTPMIDIPlugin.qtplugin"
rm -rf "$PLUGIN_ROOT/QTPTranscodePlugin.qtplugin"
cp -R "$ROOT_DIR/build/PlugIns/QTPMIDIPlugin.qtplugin" "$PLUGIN_ROOT/QTPMIDIPlugin.qtplugin"
cp -R "$ROOT_DIR/build/PlugIns/QTPTranscodePlugin.qtplugin" "$PLUGIN_ROOT/QTPTranscodePlugin.qtplugin"

if [[ ! -e "$REAL_EXECUTABLE" ]]; then
  mv "$MAIN_EXECUTABLE" "$REAL_EXECUTABLE"
fi

cp "$ROOT_DIR/build/QuickTimePlayerLauncher" "$MAIN_EXECUTABLE"
chmod +x "$MAIN_EXECUTABLE" "$REAL_EXECUTABLE"

if ! /usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes" "$INFO_PLIST" | grep -q "public.midi-audio"; then
  next_index="$(/usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes" "$INFO_PLIST" | grep -c 'Dict {')"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:$next_index dict" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:$next_index:CFBundleTypeRole string Viewer" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:$next_index:LSHandlerRank string Alternate" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:$next_index:LSItemContentTypes array" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:$next_index:LSItemContentTypes:0 string public.midi-audio" "$INFO_PLIST"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:$next_index:NSDocumentClass string MGPlaybackDocument" "$INFO_PLIST"
fi

/usr/libexec/PlistBuddy -c "Set :CFBundleName QuickTime Player Plus" "$INFO_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName QuickTime Player Plus" "$INFO_PLIST" 2>/dev/null || true
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier com.apple.QuickTimePlayerX" "$INFO_PLIST" 2>/dev/null || true

codesign --force --deep --sign - "$APP_BUNDLE"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "Installed QuickTimePlayer+ normal-launch wrapper:"
echo "$APP_BUNDLE"
