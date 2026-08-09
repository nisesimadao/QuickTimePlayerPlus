<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/banner-dark.png">
  <img alt="QuickTime Player Plus — plugin loader and legacy media bridge for QuickTime Player" src="docs/banner-light.png" width="100%">
</picture>

[![CI](https://github.com/nisesimadao/QuickTimePlayerPlus/actions/workflows/ci.yml/badge.svg)](https://github.com/nisesimadao/QuickTimePlayerPlus/actions/workflows/ci.yml)
&nbsp;![Objective-C](https://img.shields.io/badge/Objective--C-runtime_patch-2f6f6f)
&nbsp;![macOS](https://img.shields.io/badge/macOS-Apple_Silicon-black)
&nbsp;![plugins](https://img.shields.io/badge/plugins-.qtplugin-6f42c1)

QuickTime Player Plus is an experimental plugin loader and legacy media bridge for
the modern macOS QuickTime Player. It launches a locally copied QuickTime Player
with a small injected dylib, loads `*.qtplugin` bundles, and lets plugins turn
unsupported inputs into temporary media files that open in the standard
QuickTime playback window.

[日本語版 README](README-ja.md)

> **Unofficial project**: this repository does not contain or redistribute
> Apple's QuickTime Player application. The release package copies
> `/System/Applications/QuickTime Player.app` from the user's own Mac into
> `/Applications/QuickTime Player Plus.app`, then adds only the open source
> launcher, loader, icon, and plugins from this project. This project is not
> affiliated with Apple Inc.

## Quick Start

```sh
git clone https://github.com/nisesimadao/QuickTimePlayerPlus.git
cd QuickTimePlayerPlus
make install-application
open -n -a "/Applications/QuickTime Player Plus.app" ~/Downloads/example.mid
```

`make install-application` creates `/Applications/QuickTime Player Plus.app` by
copying the system QuickTime Player into the wrapper app and installing the
launcher, plugin loader, custom icon, and bundled plugins.

## Included Components

| Role | File | Description |
| --- | --- | --- |
| Loader patch | `QuickTimePlayerPlus.dylib` | Finds and loads `*.qtplugin` bundles at QuickTime launch |
| MIDI plugin | `QTPMIDIPlugin.qtplugin` | Renders `.mid/.midi` to temporary audio and opens it in QuickTime |
| Legacy media plugin | `QTPTranscodePlugin.qtplugin` | Bridges Ogg, WebM, Matroska, WMV, WMA, AVI, DivX, Xvid, and FLV through ffmpeg |
| Animated image plugin | `QTPAnimatedImagePlugin.qtplugin` | Converts GIF, WebP, AVIF, and APNG to temporary MP4 movies |
| Game audio plugin | `QTPGameAudioPlugin.qtplugin` | Opens VGM, NSF, SPC, PSF, and related files when the local ffmpeg build can decode them |
| Image sequence plugin | `QTPImageSequencePlugin.qtplugin` | Converts numbered frame sequences such as `frame_0001.png` to MP4 |
| Plugin manager | App menu | `QuickTime Player Plus Plugins...` toggles plugins and manages renderer paths |

The goal is not to revive old QuickTime component APIs directly. Instead,
QuickTime Player Plus uses focused bridge plugins that produce media formats
modern QuickTime can already play.

## How It Works

```mermaid
flowchart LR
  Finder[Finder / Open With] --> Launcher[QuickTime Player Plus.app]
  Launcher -->|DYLD_INSERT_LIBRARIES| QuickTime[Bundled QuickTime Player]
  QuickTime --> Loader[QuickTimePlayerPlus.dylib]
  Loader --> PluginDir[Plugin folders]
  PluginDir --> MIDI[QTPMIDIPlugin.qtplugin]
  PluginDir --> Transcode[QTPTranscodePlugin.qtplugin]
  PluginDir --> Animated[QTPAnimatedImagePlugin.qtplugin]
  PluginDir --> Game[QTPGameAudioPlugin.qtplugin]
  PluginDir --> Sequence[QTPImageSequencePlugin.qtplugin]
  MIDI --> Audio[Temporary WAV/CAF]
  Transcode --> MP4[Temporary MP4/M4A]
  Animated --> MP4
  Game --> M4A[Temporary M4A]
  Sequence --> MP4
  Audio --> QuickTime
  MP4 --> QuickTime
  M4A --> QuickTime
```

The wrapper app receives Finder documents, launches the copied QuickTime Player,
and injects the loader with `DYLD_INSERT_LIBRARIES`. Plugins hook selected open
paths, handle only their own extensions, write temporary media under
`$TMPDIR/QuickTimePlayerPlus`, then call back into QuickTime's normal document
opening flow.

## Plugin Locations

Bundled plugins in local builds:

```text
QuickTime Player Plus.app/
└── Contents/PlugIns/QuickTimePlayerPlus/
    ├── QTPMIDIPlugin.qtplugin
    ├── QTPTranscodePlugin.qtplugin
    └── ...
```

Plugins installed by the release package:

```text
/Library/Application Support/QuickTimePlayerPlus/PlugIns/
```

User-added plugins:

```text
~/Library/Application Support/QuickTimePlayer+/PlugIns/
```

Development-only plugin path:

```sh
QTP_PLUGIN_PATH="/path/to/PlugIns" open -n -a "/Applications/QuickTime Player Plus.app" file.mid
```

Open **QuickTime Player Plus Plugins...** from the app menu to manage plugins.

- Checkboxes enable or disable plugins on the next launch.
- **Add Plugin...** copies a `.qtplugin` bundle into the user plugin folder.
- **Open Plugin Folder** opens the user plugin folder in Finder.
- **Clear Render Caches** removes temporary render outputs.
- **Set ffmpeg...** selects the ffmpeg binary for bridge plugins.
- **Set FluidSynth...** selects the FluidSynth binary for MIDI rendering.
- **Set SoundFont...** selects the `.sf2/.sf3/.dls` file used by FluidSynth.

## MIDI Rendering

The MIDI plugin renders in this order:

1. FluidSynth, when both `fluidsynth` and a SoundFont or DLS file are available.
2. Apple's DLS Music Device as a fallback.

Apple's fallback handles MIDI events such as velocity and program changes, but
many common MIDI players sound closer to a General MIDI or GS SoundFont. For the
best result, install FluidSynth and choose a SoundFont in the plugin manager.

```sh
brew install fluid-synth
```

The Game Audio plugin also depends on ffmpeg. Some ffmpeg builds do not include
game music decoders, so files such as `.vgm` or `.spc` may need a build with
libgme or vgmstream support.

## Building

Requirements:

- macOS on Apple Silicon
- Xcode Command Line Tools
- `ffmpeg` for the legacy media, animated image, image sequence, and game audio bridges

```sh
make all
make install-application
```

Open the installed app:

```sh
open -n -a "/Applications/QuickTime Player Plus.app"
open -n -a "/Applications/QuickTime Player Plus.app" ~/Downloads/example.mid
```

## Plugin API

Plugins are standard macOS bundles with a `.qtplugin` extension. Each bundle
exports `QTPPluginMain`.

```objc
#import <Foundation/Foundation.h>
#import "QTPPlugin.h"

void QTPPluginMain(void)
{
    QTPLog(@"MyPlugin loaded");
}
```

`Contents/Info.plist` can declare `QTPPluginSupportedExtensions` and
`QTPPluginDescription` for the plugin manager. See
[docs/plugin-development.md](docs/plugin-development.md) for the full plugin
guide.

## Releases

Pushing a version tag builds and uploads these assets with GitHub Actions:

- `QuickTimePlayerPlus-<version>.pkg`
- `QuickTimePlayerPlus-<version>.dmg`
- `QuickTimePlayerPlus-<version>-plugins.zip`
- `SHA256SUMS.txt`

The `.pkg` does not contain Apple's app bundle. At install time it copies the
local system QuickTime Player and creates `/Applications/QuickTime Player Plus.app`.

The package includes selectable plugin components in Installer's
**Customize** screen. Every bundled plugin is selected by default.

```mermaid
flowchart TD
  PKG[QuickTimePlayerPlus.pkg] --> Core[Core launcher + loader]
  PKG --> MIDI[MIDI Plugin]
  PKG --> Legacy[Legacy Media Plugin]
  PKG --> Animated[Animated Image Plugin]
  PKG --> Game[Game Audio Plugin]
  PKG --> Sequence[Image Sequence Plugin]
  MIDI --> Store[/Library/Application Support/QuickTimePlayerPlus/PlugIns]
  Legacy --> Store
  Animated --> Store
  Game --> Store
  Sequence --> Store
  Core --> App[/Applications/QuickTime Player Plus.app]
```

```sh
git tag v0.1.1
git push origin v0.1.1
```

## Notes

- This is an experiment based on private behavior and dylib injection. macOS
  updates can break it.
- The system `/System/Applications/QuickTime Player.app` is never modified.
- Bridge plugins create temporary files under `$TMPDIR/QuickTimePlayerPlus`.
- The current local install uses ad-hoc signing. Unsigned release builds may
  trigger Gatekeeper warnings.

## Credits

- [FluidSynth](https://www.fluidsynth.org/) for optional MIDI rendering.
- [FFmpeg](https://ffmpeg.org/) for legacy media, animated image, image sequence,
  and game audio bridge conversions.
- Apple's QuickTime Player icon is used only as a local visual reference; this
  repository does not redistribute Apple application bundles.
