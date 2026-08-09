#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_APP="${SOURCE_QUICKTIME_APP:-/System/Applications/QuickTime Player.app}"
APP_BUNDLE="$ROOT_DIR/dist/QuickTime Player Plus.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
PLUGIN_ROOT="$CONTENTS_DIR/PlugIns/QuickTimePlayerPlus"

add_plus_document_type() {
  local plist="$1"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0 dict" "$plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:CFBundleTypeName string 'QuickTime Player Plus Supported Media'" "$plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:CFBundleTypeRole string Viewer" "$plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSHandlerRank string Alternate" "$plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:NSDocumentClass string MGPlaybackDocument" "$plist"
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:CFBundleTypeExtensions array" "$plist"
  for extension in mid midi ogg oga ogv webm mkv wmv wma avi divx xvid flv gif webp avif apng vgm vgz nsf spc psf psf2 minipsf minipsf2 png jpg jpeg tif tiff exr dpx; do
    /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:CFBundleTypeExtensions: string $extension" "$plist"
  done
  /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes array" "$plist"
  for type in public.midi-audio public.audiovisual-content public.movie public.audio public.image public.png public.jpeg public.tiff public.data; do
    /usr/libexec/PlistBuddy -c "Add :CFBundleDocumentTypes:0:LSItemContentTypes: string $type" "$plist"
  done
}

cd "$ROOT_DIR"
make all

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Source QuickTime app not found: $SOURCE_APP" >&2
  exit 1
fi

if [[ -d "$APP_BUNDLE" ]]; then
  backup="$ROOT_DIR/dist/QuickTime Player Plus.$(date +%Y%m%d-%H%M%S).app"
  mv "$APP_BUNDLE" "$backup"
fi

mkdir -p "$MACOS_DIR" "$RESOURCES_DIR" "$PLUGIN_ROOT"
cp resources/QuickTimePlayerPlus-Info.plist "$CONTENTS_DIR/Info.plist"
cp -R resources/en.lproj "$RESOURCES_DIR/en.lproj"
cp -R resources/ja.lproj "$RESOURCES_DIR/ja.lproj"
cp build/QuickTimePlayerApplicationLauncher "$MACOS_DIR/QuickTime Player Plus"
cp resources/AppIcon.icns "$RESOURCES_DIR/AppIcon.icns"
cp -R "$SOURCE_APP" "$RESOURCES_DIR/QuickTime Player.app"
cp resources/AppIcon.icns "$RESOURCES_DIR/QuickTime Player.app/Contents/Resources/AppIcon.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName QuickTime Player Plus" "$RESOURCES_DIR/QuickTime Player.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleName QuickTime Player Plus" "$RESOURCES_DIR/QuickTime Player.app/Contents/Info.plist"
add_plus_document_type "$RESOURCES_DIR/QuickTime Player.app/Contents/Info.plist"
cp build/QuickTimePlayerPlus.dylib "$PLUGIN_ROOT/QuickTimePlayerPlus.dylib"
cp -R build/PlugIns/*.qtplugin "$PLUGIN_ROOT/"
chmod +x "$MACOS_DIR/QuickTime Player Plus"

codesign --force --deep --sign - "$RESOURCES_DIR/QuickTime Player.app"
codesign --force --deep --sign - "$APP_BUNDLE"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE" >/dev/null 2>&1 || true

echo "$APP_BUNDLE"
