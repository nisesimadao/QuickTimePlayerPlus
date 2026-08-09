#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VERSION="${1:-0.1.0}"
DIST_DIR="$ROOT_DIR/dist"
STAGE_DIR="$ROOT_DIR/build/package"
CORE_PAYLOAD_DIR="$STAGE_DIR/core-payload"
SCRIPTS_DIR="$STAGE_DIR/scripts"
SUPPORT_DIR="$CORE_PAYLOAD_DIR/Library/Application Support/QuickTimePlayerPlus"
COMPONENT_DIR="$STAGE_DIR/components"

cd "$ROOT_DIR"
make all

rm -rf "$STAGE_DIR"
mkdir -p "$DIST_DIR" "$SUPPORT_DIR" "$SCRIPTS_DIR" "$COMPONENT_DIR"
cp build/QuickTimePlayerPlus.dylib "$SUPPORT_DIR/QuickTimePlayerPlus.dylib"
cp build/QuickTimePlayerApplicationLauncher "$SUPPORT_DIR/QuickTimePlayerApplicationLauncher"
cp resources/QuickTimePlayerPlus-Info.plist "$SUPPORT_DIR/QuickTimePlayerPlus-Info.plist"
cp resources/AppIcon.icns "$SUPPORT_DIR/AppIcon.icns"
mkdir -p "$SUPPORT_DIR/Resources"
cp -R resources/en.lproj "$SUPPORT_DIR/Resources/en.lproj"
cp -R resources/ja.lproj "$SUPPORT_DIR/Resources/ja.lproj"
cp package/pkg-scripts/postinstall "$SCRIPTS_DIR/postinstall"
chmod +x "$SCRIPTS_DIR/postinstall"

PKG="$DIST_DIR/QuickTimePlayerPlus-$VERSION.pkg"
DMG_ROOT="$STAGE_DIR/dmg-root"
DMG="$DIST_DIR/QuickTimePlayerPlus-$VERSION.dmg"
ZIP="$DIST_DIR/QuickTimePlayerPlus-$VERSION-plugins.zip"

pkgbuild \
  --root "$CORE_PAYLOAD_DIR" \
  --scripts "$SCRIPTS_DIR" \
  --identifier "local.quicktimeplayerplus.core" \
  --version "$VERSION" \
  --install-location "/" \
  "$COMPONENT_DIR/core.pkg"

plugin_component() {
  local bundle_name="$1"
  local identifier="$2"
  local payload="$STAGE_DIR/plugin-payload-$identifier"
  mkdir -p "$payload/Library/Application Support/QuickTimePlayerPlus/PlugIns"
  cp -R "build/PlugIns/$bundle_name" "$payload/Library/Application Support/QuickTimePlayerPlus/PlugIns/$bundle_name"
  pkgbuild \
    --root "$payload" \
    --identifier "$identifier" \
    --version "$VERSION" \
    --install-location "/" \
    "$COMPONENT_DIR/$identifier.pkg"
}

plugin_component "QTPMIDIPlugin.qtplugin" "local.quicktimeplayerplus.plugin.midi"
plugin_component "QTPTranscodePlugin.qtplugin" "local.quicktimeplayerplus.plugin.transcode"
plugin_component "QTPAnimatedImagePlugin.qtplugin" "local.quicktimeplayerplus.plugin.animated-image"
plugin_component "QTPGameAudioPlugin.qtplugin" "local.quicktimeplayerplus.plugin.game-audio"
plugin_component "QTPImageSequencePlugin.qtplugin" "local.quicktimeplayerplus.plugin.image-sequence"

cat > "$STAGE_DIR/Distribution.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<installer-gui-script minSpecVersion="2">
  <title>QuickTime Player Plus</title>
  <options customize="always" require-scripts="true"/>
  <choices-outline>
    <line choice="core"/>
    <line choice="plugin-midi"/>
    <line choice="plugin-transcode"/>
    <line choice="plugin-animated-image"/>
    <line choice="plugin-game-audio"/>
    <line choice="plugin-image-sequence"/>
  </choices-outline>
  <choice id="core" title="QuickTime Player Plus" description="Launcher, plugin loader, and support files." enabled="false" selected="true">
    <pkg-ref id="local.quicktimeplayerplus.core"/>
  </choice>
  <choice id="plugin-midi" title="MIDI Plugin" description="Open .mid and .midi files in the QuickTime playback window." selected="true">
    <pkg-ref id="local.quicktimeplayerplus.plugin.midi"/>
  </choice>
  <choice id="plugin-transcode" title="Legacy Media Plugin" description="Open Ogg, WebM, Matroska, WMV, WMA, AVI, DivX, Xvid, and FLV through ffmpeg." selected="true">
    <pkg-ref id="local.quicktimeplayerplus.plugin.transcode"/>
  </choice>
  <choice id="plugin-animated-image" title="Animated Image Plugin" description="Open GIF, WebP, AVIF, and APNG as temporary MP4 movies." selected="true">
    <pkg-ref id="local.quicktimeplayerplus.plugin.animated-image"/>
  </choice>
  <choice id="plugin-game-audio" title="Game Audio Plugin" description="Open VGM, NSF, SPC, PSF, and related files when the local ffmpeg build supports them." selected="true">
    <pkg-ref id="local.quicktimeplayerplus.plugin.game-audio"/>
  </choice>
  <choice id="plugin-image-sequence" title="Image Sequence Plugin" description="Open numbered image sequences as temporary MP4 movies." selected="true">
    <pkg-ref id="local.quicktimeplayerplus.plugin.image-sequence"/>
  </choice>
  <pkg-ref id="local.quicktimeplayerplus.core" version="$VERSION" onConclusion="none">core.pkg</pkg-ref>
  <pkg-ref id="local.quicktimeplayerplus.plugin.midi" version="$VERSION" onConclusion="none">local.quicktimeplayerplus.plugin.midi.pkg</pkg-ref>
  <pkg-ref id="local.quicktimeplayerplus.plugin.transcode" version="$VERSION" onConclusion="none">local.quicktimeplayerplus.plugin.transcode.pkg</pkg-ref>
  <pkg-ref id="local.quicktimeplayerplus.plugin.animated-image" version="$VERSION" onConclusion="none">local.quicktimeplayerplus.plugin.animated-image.pkg</pkg-ref>
  <pkg-ref id="local.quicktimeplayerplus.plugin.game-audio" version="$VERSION" onConclusion="none">local.quicktimeplayerplus.plugin.game-audio.pkg</pkg-ref>
  <pkg-ref id="local.quicktimeplayerplus.plugin.image-sequence" version="$VERSION" onConclusion="none">local.quicktimeplayerplus.plugin.image-sequence.pkg</pkg-ref>
</installer-gui-script>
EOF

productbuild \
  --distribution "$STAGE_DIR/Distribution.xml" \
  --package-path "$COMPONENT_DIR" \
  "$PKG"

ditto -c -k --keepParent "build/PlugIns" "$ZIP"

mkdir -p "$DMG_ROOT"
cp "$PKG" "$DMG_ROOT/"
cp README.md "$DMG_ROOT/README.md"
cp README-ja.md "$DMG_ROOT/README-ja.md"
hdiutil create -volname "QuickTimePlayerPlus $VERSION" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG"

(
  cd "$DIST_DIR"
  shasum -a 256 "QuickTimePlayerPlus-$VERSION.pkg" "QuickTimePlayerPlus-$VERSION.dmg" "QuickTimePlayerPlus-$VERSION-plugins.zip" > SHA256SUMS.txt
)

ls -la "$DIST_DIR"
