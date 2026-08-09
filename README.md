<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/banner-dark.svg">
  <img alt="QuickTime Player+ — plugin loader and legacy media bridge for QuickTime Player" src="docs/banner-light.svg" width="100%">
</picture>

[![CI](https://github.com/nisesimadao/QuickTimePlayerPlus/actions/workflows/ci.yml/badge.svg)](https://github.com/nisesimadao/QuickTimePlayerPlus/actions/workflows/ci.yml)
&nbsp;![Objective-C](https://img.shields.io/badge/Objective--C-runtime_patch-2f6f6f)
&nbsp;![macOS](https://img.shields.io/badge/macOS-Apple_Silicon-black)
&nbsp;![plugins](https://img.shields.io/badge/plugins-.qtplugin-6f42c1)

QuickTime Player にプラグイン機構を足す実験です。起動時に小さな dylib を注入し、
`*.qtplugin` bundle を読み込みます。MIDI や QuickTime 7 時代の外部 component が担っていた
形式を、今の QuickTime が読める一時メディアへ変換して、**QuickTime 標準の再生ウィンドウ**で
開きます。

> **非公式・再配布制約** — このリポジトリは Apple の QuickTime Player 本体を含みません。
> Release の `.pkg` はインストール先 Mac にある `/System/Applications/QuickTime Player.app`
> をその場で `/Applications/QuickTime Player+.app` へコピーし、自作ローダーとプラグインだけを
> 追加します。Apple Inc. とは無関係です。

## まず試すなら

```sh
git clone https://github.com/nisesimadao/QuickTimePlayerPlus.git
cd QuickTimePlayerPlus
make install-application
open -n -a "/Applications/QuickTime Player+.app" ~/Downloads/example.mid
```

`make install-application` は `/System/Applications/QuickTime Player.app` を
`/Applications/QuickTime Player+.app` の内側へコピーし、自作 launcher / plugin loader /
プリインストールプラグインを組み込みます。

## 入っているもの

| 役割 | ファイル | 内容 |
| --- | --- | --- |
| パッチ / ローダー | `QuickTimePlayerPlus.dylib` | QuickTime 起動時に `*.qtplugin` を探して読み込む |
| MIDI plugin | `QTPMIDIPlugin.qtplugin` | `.mid/.midi` を一時 `.caf` にレンダリングして QuickTime に渡す |
| Legacy media plugin | `QTPTranscodePlugin.qtplugin` | Ogg / WebM / Matroska / WMV / WMA / AVI / DivX / Xvid / FLV を ffmpeg で QuickTime 向けへ変換 |
| 管理画面 | app menu | `QuickTimePlayer+ Plugins...` で次回起動時の有効/無効を切り替える |

QuickTime 7 時代によく使われた Perian / Flip4Mac / XiphQT / DivX / Xvid 系の役割を、
今の QuickTime の codec component として復活させるのではなく、プラグインごとの
変換ブリッジとして実装しています。

## ビルド

要件:

- macOS on Apple Silicon
- Xcode Command Line Tools
- `ffmpeg`（Legacy media plugin 用。Homebrew なら `/opt/homebrew/bin/ffmpeg`）

```sh
make all
```

通常起動できるアプリを `/Applications` に作る:

```sh
make install-application
```

開く:

```sh
open -n -a "/Applications/QuickTime Player+.app"
open -n -a "/Applications/QuickTime Player+.app" ~/Downloads/example.mid
```

## プラグインの形

プラグインは bundle です。`Contents/Info.plist` に通常の bundle 情報と
`QTPPluginSupportedExtensions` / `QTPPluginDescription` を入れ、実行ファイル側で
`QTPPluginMain` を export します。

```objc
void QTPPluginMain(void)
{
    // Hook QuickTime behavior here.
}
```

ローダーは以下を探します。

- `QTP_PLUGIN_PATH`
- `QuickTime Player+.app/Contents/PlugIns/QuickTimePlayerPlus`
- `~/Library/Application Support/QuickTimePlayer+/PlugIns`

## Release

タグを push すると GitHub Actions が以下を作って Release に添付します。

- `QuickTimePlayerPlus-<version>.pkg`
- `QuickTimePlayerPlus-<version>.dmg`
- `QuickTimePlayerPlus-<version>-plugins.zip`
- `SHA256SUMS.txt`

`.pkg` は Apple の app bundle を含みません。インストール時にローカルの QuickTime Player を
コピーして `/Applications/QuickTime Player+.app` を作ります。

```sh
git tag v0.1.0
git push origin v0.1.0
```

## 注意

- これは private API と dylib injection を使う実験です。macOS のアップデートで壊れます。
- システム標準の `/System/Applications/QuickTime Player.app` は直接変更しません。
- 変換系プラグインは一時ファイルを作ります。次回起動時に専用キャッシュを削除します。
- 署名は ad-hoc です。配布物は Gatekeeper の警告が出ます。
