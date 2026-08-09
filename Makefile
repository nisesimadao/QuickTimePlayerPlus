SDKROOT := $(shell xcrun --sdk macosx --show-sdk-path)
ARCH := arm64e
BUILD_DIR := build
INCLUDE_DIR := include

COMMON_CFLAGS := -arch $(ARCH) -isysroot $(SDKROOT) -mmacosx-version-min=14.0 -fobjc-arc -fmodules -I$(INCLUDE_DIR) -Wall -Wextra -Werror
COMMON_LDFLAGS := -arch $(ARCH) -isysroot $(SDKROOT) -mmacosx-version-min=14.0

INJECTOR := $(BUILD_DIR)/QuickTimePlayerPlus.dylib
LAUNCHER := $(BUILD_DIR)/QuickTimePlayerLauncher
APPLICATION_LAUNCHER := $(BUILD_DIR)/QuickTimePlayerApplicationLauncher
MIDI_PLUGIN_BUNDLE := $(BUILD_DIR)/PlugIns/QTPMIDIPlugin.qtplugin
MIDI_PLUGIN_EXECUTABLE := $(MIDI_PLUGIN_BUNDLE)/Contents/MacOS/QTPMIDIPlugin
TRANSCODE_PLUGIN_BUNDLE := $(BUILD_DIR)/PlugIns/QTPTranscodePlugin.qtplugin
TRANSCODE_PLUGIN_EXECUTABLE := $(TRANSCODE_PLUGIN_BUNDLE)/Contents/MacOS/QTPTranscodePlugin
ANIMATED_IMAGE_PLUGIN_BUNDLE := $(BUILD_DIR)/PlugIns/QTPAnimatedImagePlugin.qtplugin
ANIMATED_IMAGE_PLUGIN_EXECUTABLE := $(ANIMATED_IMAGE_PLUGIN_BUNDLE)/Contents/MacOS/QTPAnimatedImagePlugin
GAME_AUDIO_PLUGIN_BUNDLE := $(BUILD_DIR)/PlugIns/QTPGameAudioPlugin.qtplugin
GAME_AUDIO_PLUGIN_EXECUTABLE := $(GAME_AUDIO_PLUGIN_BUNDLE)/Contents/MacOS/QTPGameAudioPlugin
IMAGE_SEQUENCE_PLUGIN_BUNDLE := $(BUILD_DIR)/PlugIns/QTPImageSequencePlugin.qtplugin
IMAGE_SEQUENCE_PLUGIN_EXECUTABLE := $(IMAGE_SEQUENCE_PLUGIN_BUNDLE)/Contents/MacOS/QTPImageSequencePlugin

.PHONY: all clean install-plugins install-normal-launch

all: $(INJECTOR) $(LAUNCHER) $(APPLICATION_LAUNCHER) $(MIDI_PLUGIN_EXECUTABLE) $(TRANSCODE_PLUGIN_EXECUTABLE) $(ANIMATED_IMAGE_PLUGIN_EXECUTABLE) $(GAME_AUDIO_PLUGIN_EXECUTABLE) $(IMAGE_SEQUENCE_PLUGIN_EXECUTABLE)

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(INJECTOR): src/QTPInjector.m include/QTPPlugin.h | $(BUILD_DIR)
	clang $(COMMON_CFLAGS) -dynamiclib src/QTPInjector.m -o $@ $(COMMON_LDFLAGS) -framework Foundation -framework AppKit
	codesign --force --sign - $@

$(LAUNCHER): src/QTPAppLauncher.m | $(BUILD_DIR)
	clang $(COMMON_CFLAGS) src/QTPAppLauncher.m -o $@ $(COMMON_LDFLAGS) -framework Foundation
	codesign --force --sign - $@

$(APPLICATION_LAUNCHER): src/QTPApplicationLauncher.m | $(BUILD_DIR)
	clang $(COMMON_CFLAGS) src/QTPApplicationLauncher.m -o $@ $(COMMON_LDFLAGS) -framework Foundation -framework AppKit
	codesign --force --sign - $@

install-application: all
	./script/build_application_bundle.sh
	if [ -d "/Applications/QuickTime Player Plus.app" ]; then mv "/Applications/QuickTime Player Plus.app" "/Applications/QuickTime Player Plus.$$(date +%Y%m%d-%H%M%S).app"; fi
	cp -R "dist/QuickTime Player Plus.app" "/Applications/QuickTime Player Plus.app"

$(MIDI_PLUGIN_EXECUTABLE): plugins/MIDIPlugin/QTPMIDIPlugin.m plugins/MIDIPlugin/Info.plist include/QTPPlugin.h | $(BUILD_DIR)
	mkdir -p $(MIDI_PLUGIN_BUNDLE)/Contents/MacOS
	cp plugins/MIDIPlugin/Info.plist $(MIDI_PLUGIN_BUNDLE)/Contents/Info.plist
	clang $(COMMON_CFLAGS) -bundle plugins/MIDIPlugin/QTPMIDIPlugin.m -o $@ $(COMMON_LDFLAGS) -framework Foundation -framework AppKit -framework AVFAudio -framework AudioToolbox
	codesign --force --sign - $(MIDI_PLUGIN_BUNDLE)

$(TRANSCODE_PLUGIN_EXECUTABLE): plugins/TranscodePlugin/QTPTranscodePlugin.m plugins/TranscodePlugin/Info.plist include/QTPPlugin.h | $(BUILD_DIR)
	mkdir -p $(TRANSCODE_PLUGIN_BUNDLE)/Contents/MacOS
	cp plugins/TranscodePlugin/Info.plist $(TRANSCODE_PLUGIN_BUNDLE)/Contents/Info.plist
	clang $(COMMON_CFLAGS) -bundle plugins/TranscodePlugin/QTPTranscodePlugin.m -o $@ $(COMMON_LDFLAGS) -framework Foundation -framework AppKit -framework AVFoundation
	codesign --force --sign - $(TRANSCODE_PLUGIN_BUNDLE)

$(ANIMATED_IMAGE_PLUGIN_EXECUTABLE): plugins/AnimatedImagePlugin/QTPAnimatedImagePlugin.m plugins/AnimatedImagePlugin/Info.plist include/QTPPlugin.h | $(BUILD_DIR)
	mkdir -p $(ANIMATED_IMAGE_PLUGIN_BUNDLE)/Contents/MacOS
	cp plugins/AnimatedImagePlugin/Info.plist $(ANIMATED_IMAGE_PLUGIN_BUNDLE)/Contents/Info.plist
	clang $(COMMON_CFLAGS) -bundle plugins/AnimatedImagePlugin/QTPAnimatedImagePlugin.m -o $@ $(COMMON_LDFLAGS) -framework Foundation -framework AppKit
	codesign --force --sign - $(ANIMATED_IMAGE_PLUGIN_BUNDLE)

$(GAME_AUDIO_PLUGIN_EXECUTABLE): plugins/GameAudioPlugin/QTPGameAudioPlugin.m plugins/GameAudioPlugin/Info.plist include/QTPPlugin.h | $(BUILD_DIR)
	mkdir -p $(GAME_AUDIO_PLUGIN_BUNDLE)/Contents/MacOS
	cp plugins/GameAudioPlugin/Info.plist $(GAME_AUDIO_PLUGIN_BUNDLE)/Contents/Info.plist
	clang $(COMMON_CFLAGS) -bundle plugins/GameAudioPlugin/QTPGameAudioPlugin.m -o $@ $(COMMON_LDFLAGS) -framework Foundation -framework AppKit
	codesign --force --sign - $(GAME_AUDIO_PLUGIN_BUNDLE)

$(IMAGE_SEQUENCE_PLUGIN_EXECUTABLE): plugins/ImageSequencePlugin/QTPImageSequencePlugin.m plugins/ImageSequencePlugin/Info.plist include/QTPPlugin.h | $(BUILD_DIR)
	mkdir -p $(IMAGE_SEQUENCE_PLUGIN_BUNDLE)/Contents/MacOS
	cp plugins/ImageSequencePlugin/Info.plist $(IMAGE_SEQUENCE_PLUGIN_BUNDLE)/Contents/Info.plist
	clang $(COMMON_CFLAGS) -bundle plugins/ImageSequencePlugin/QTPImageSequencePlugin.m -o $@ $(COMMON_LDFLAGS) -framework Foundation -framework AppKit
	codesign --force --sign - $(IMAGE_SEQUENCE_PLUGIN_BUNDLE)

install-plugins: all
	mkdir -p "QuickTime Player Plus.app/Contents/PlugIns/QuickTimePlayerPlus"
	rm -rf "QuickTime Player Plus.app/Contents/PlugIns/QuickTimePlayerPlus/QTPMIDIPlugin.qtplugin"
	rm -rf "QuickTime Player Plus.app/Contents/PlugIns/QuickTimePlayerPlus/QTPTranscodePlugin.qtplugin"
	rm -rf "QuickTime Player Plus.app/Contents/PlugIns/QuickTimePlayerPlus/QTPAnimatedImagePlugin.qtplugin"
	rm -rf "QuickTime Player Plus.app/Contents/PlugIns/QuickTimePlayerPlus/QTPGameAudioPlugin.qtplugin"
	rm -rf "QuickTime Player Plus.app/Contents/PlugIns/QuickTimePlayerPlus/QTPImageSequencePlugin.qtplugin"
	cp -R $(MIDI_PLUGIN_BUNDLE) "QuickTime Player Plus.app/Contents/PlugIns/QuickTimePlayerPlus/"
	cp -R $(TRANSCODE_PLUGIN_BUNDLE) "QuickTime Player Plus.app/Contents/PlugIns/QuickTimePlayerPlus/"
	cp -R $(ANIMATED_IMAGE_PLUGIN_BUNDLE) "QuickTime Player Plus.app/Contents/PlugIns/QuickTimePlayerPlus/"
	cp -R $(GAME_AUDIO_PLUGIN_BUNDLE) "QuickTime Player Plus.app/Contents/PlugIns/QuickTimePlayerPlus/"
	cp -R $(IMAGE_SEQUENCE_PLUGIN_BUNDLE) "QuickTime Player Plus.app/Contents/PlugIns/QuickTimePlayerPlus/"

install-normal-launch: all
	./script/install_normal_launch.sh

clean:
	rm -rf $(BUILD_DIR)
