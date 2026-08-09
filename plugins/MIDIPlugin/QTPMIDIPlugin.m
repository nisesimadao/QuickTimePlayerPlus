#import <AppKit/AppKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFAudio/AVFAudio.h>
#import <objc/runtime.h>
#import "QTPPlugin.h"

static NSMutableSet<NSString *> *QTPMIDISwizzledClassNames;
static NSMutableArray<NSURL *> *QTPRenderedMIDIURLs;

static BOOL QTPIsMIDIURL(NSURL *url)
{
    NSString *extension = url.pathExtension.lowercaseString;
    return [extension isEqualToString:@"mid"] || [extension isEqualToString:@"midi"];
}

static AVAudioUnitMIDIInstrument *QTPCreateDLSMusicDevice(void)
{
    AudioComponentDescription description;
    description.componentType = kAudioUnitType_MusicDevice;
    description.componentSubType = kAudioUnitSubType_DLSSynth;
    description.componentManufacturer = kAudioUnitManufacturer_Apple;
    description.componentFlags = 0;
    description.componentFlagsMask = 0;

    return [[AVAudioUnitMIDIInstrument alloc] initWithAudioComponentDescription:description];
}

static NSTimeInterval QTPMIDIDuration(AVAudioSequencer *sequencer)
{
    NSTimeInterval duration = 0;
    for (AVMusicTrack *track in sequencer.tracks) {
        duration = MAX(duration, track.lengthInSeconds);
    }
    return MAX(duration + 1.5, 1.0);
}

static NSURL *QTPRenderedMIDIURLForURL(NSURL *midiURL)
{
    NSString *baseName = midiURL.URLByDeletingPathExtension.lastPathComponent ?: @"Rendered MIDI";
    NSString *fileName = [NSString stringWithFormat:@"%@-%@.caf", baseName, NSUUID.UUID.UUIDString];
    NSURL *directoryURL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:@"QuickTimePlayerPlus/MIDI" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directoryURL
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    return [directoryURL URLByAppendingPathComponent:fileName];
}

static NSURL *QTPFluidSynthRenderedMIDIURLForURL(NSURL *midiURL)
{
    NSString *baseName = midiURL.URLByDeletingPathExtension.lastPathComponent ?: @"Rendered MIDI";
    NSString *fileName = [NSString stringWithFormat:@"%@-%@.wav", baseName, NSUUID.UUID.UUIDString];
    NSURL *directoryURL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:@"QuickTimePlayerPlus/MIDI" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directoryURL
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    return [directoryURL URLByAppendingPathComponent:fileName];
}

static NSString *QTPFindExecutable(NSArray<NSString *> *paths)
{
    for (NSString *path in paths) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static NSString *QTPFindFluidSynthPath(void)
{
    NSString *configuredPath = [NSUserDefaults.standardUserDefaults stringForKey:@"QTPFluidSynthPath"];
    if (configuredPath.length > 0 && [NSFileManager.defaultManager isExecutableFileAtPath:configuredPath]) {
        return configuredPath;
    }

    return QTPFindExecutable(@[
        @"/opt/homebrew/bin/fluidsynth",
        @"/usr/local/bin/fluidsynth",
        @"/opt/local/bin/fluidsynth"
    ]);
}

static NSString *QTPFindMIDISoundFontPath(void)
{
    NSString *configuredPath = [NSUserDefaults.standardUserDefaults stringForKey:@"QTPMIDISoundFontPath"];
    if (configuredPath.length > 0 && [NSFileManager.defaultManager fileExistsAtPath:configuredPath]) {
        return configuredPath;
    }

    NSArray<NSString *> *candidates = @[
        @"/opt/homebrew/share/soundfonts/GeneralUser_GS.sf2",
        @"/opt/homebrew/share/sounds/sf2/FluidR3_GM.sf2",
        @"/usr/local/share/soundfonts/GeneralUser_GS.sf2",
        @"/usr/local/share/sounds/sf2/FluidR3_GM.sf2",
        @"/Library/Audio/Sounds/Banks/GeneralUser_GS.sf2",
        @"/System/Library/Components/CoreAudio.component/Contents/Resources/gs_instruments.dls"
    ];

    for (NSString *path in candidates) {
        if ([NSFileManager.defaultManager fileExistsAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static void QTPCleanupRenderedMIDICache(void)
{
    NSURL *directoryURL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:@"QuickTimePlayerPlus/MIDI" isDirectory:YES];
    NSFileManager *fileManager = NSFileManager.defaultManager;

    NSArray<NSURL *> *contents = [fileManager contentsOfDirectoryAtURL:directoryURL
                                            includingPropertiesForKeys:nil
                                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                 error:nil];
    NSUInteger removedCount = 0;
    for (NSURL *url in contents) {
        NSString *extension = url.pathExtension.lowercaseString;
        if (([extension isEqualToString:@"caf"] || [extension isEqualToString:@"wav"]) &&
            [fileManager removeItemAtURL:url error:nil]) {
            removedCount++;
        }
    }

    if (removedCount > 0) {
        QTPLog(@"Removed %lu cached rendered MIDI file%@", removedCount, removedCount == 1 ? @"" : @"s");
    }
}

static NSURL *QTPRenderMIDIWithFluidSynthToAudioURL(NSURL *midiURL, NSError **outError)
{
    NSString *fluidSynthPath = QTPFindFluidSynthPath();
    NSString *soundFontPath = QTPFindMIDISoundFontPath();
    if (!fluidSynthPath || !soundFontPath) {
        return nil;
    }

    NSURL *outputURL = QTPFluidSynthRenderedMIDIURLForURL(midiURL);
    QTPLog(@"Rendering MIDI with FluidSynth: %@", midiURL.path);

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:fluidSynthPath];
    task.arguments = @[
        @"-ni",
        @"-F", outputURL.path,
        @"-T", @"wav",
        @"-r", @"44100",
        @"-g", @"1.0",
        soundFontPath,
        midiURL.path
    ];

    NSPipe *errorPipe = [NSPipe pipe];
    task.standardError = errorPipe;

    NSError *launchError = nil;
    if (![task launchAndReturnError:&launchError]) {
        if (outError) {
            *outError = launchError;
        }
        return nil;
    }

    [task waitUntilExit];
    NSData *errorData = [errorPipe.fileHandleForReading readDataToEndOfFile];
    NSString *fluidSynthError = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding] ?: @"";

    if (task.terminationStatus != 0) {
        if (outError) {
            NSString *description = fluidSynthError.length > 0 ? fluidSynthError : @"FluidSynth failed to render the MIDI file.";
            *outError = [NSError errorWithDomain:@"QuickTimePlayerPlus.MIDI.FluidSynth"
                                           code:task.terminationStatus
                                       userInfo:@{NSLocalizedDescriptionKey: description}];
        }
        return nil;
    }

    [QTPRenderedMIDIURLs addObject:outputURL];
    QTPLog(@"Rendered MIDI audio with FluidSynth: %@", outputURL.path);
    return outputURL;
}

static NSURL *QTPRenderMIDIWithAppleDLSToAudioURL(NSURL *midiURL, NSError **outError)
{
    QTPLog(@"Rendering MIDI with Apple DLS: %@", midiURL.path);

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioUnitMIDIInstrument *synth = QTPCreateDLSMusicDevice();
    [engine attachNode:synth];

    AVAudioFormat *renderFormat = [[AVAudioFormat alloc] initStandardFormatWithSampleRate:44100 channels:2];
    [engine connect:synth to:engine.mainMixerNode format:renderFormat];

    NSError *error = nil;
    AVAudioSequencer *sequencer = [[AVAudioSequencer alloc] initWithAudioEngine:engine];
    if (![sequencer loadFromURL:midiURL options:AVMusicSequenceLoadSMF_PreserveTracks error:&error]) {
        if (outError) {
            *outError = error;
        }
        return nil;
    }

    for (AVMusicTrack *track in sequencer.tracks) {
        track.destinationAudioUnit = synth;
    }

    if (![engine enableManualRenderingMode:AVAudioEngineManualRenderingModeOffline
                                    format:renderFormat
                         maximumFrameCount:4096
                                     error:&error]) {
        if (outError) {
            *outError = error;
        }
        return nil;
    }

    NSURL *outputURL = QTPRenderedMIDIURLForURL(midiURL);
    AVAudioFile *outputFile = [[AVAudioFile alloc] initForWriting:outputURL
                                                         settings:renderFormat.settings
                                                            error:&error];
    if (!outputFile) {
        if (outError) {
            *outError = error;
        }
        return nil;
    }

    if (![engine startAndReturnError:&error]) {
        if (outError) {
            *outError = error;
        }
        return nil;
    }

    [sequencer prepareToPlay];
    if (![sequencer startAndReturnError:&error]) {
        [engine stop];
        if (outError) {
            *outError = error;
        }
        return nil;
    }

    NSTimeInterval duration = QTPMIDIDuration(sequencer);
    AVAudioFramePosition totalFrames = (AVAudioFramePosition)ceil(duration * renderFormat.sampleRate);
    AVAudioPCMBuffer *buffer = [[AVAudioPCMBuffer alloc] initWithPCMFormat:engine.manualRenderingFormat
                                                             frameCapacity:engine.manualRenderingMaximumFrameCount];

    while (engine.manualRenderingSampleTime < totalFrames) {
        AVAudioFramePosition remainingFrames = totalFrames - engine.manualRenderingSampleTime;
        AVAudioFrameCount frameCount = (AVAudioFrameCount)MIN((AVAudioFramePosition)buffer.frameCapacity, remainingFrames);
        AVAudioEngineManualRenderingStatus status = [engine renderOffline:frameCount toBuffer:buffer error:&error];

        switch (status) {
            case AVAudioEngineManualRenderingStatusSuccess:
                if (![outputFile writeFromBuffer:buffer error:&error]) {
                    [sequencer stop];
                    [engine stop];
                    if (outError) {
                        *outError = error;
                    }
                    return nil;
                }
                break;
            case AVAudioEngineManualRenderingStatusInsufficientDataFromInputNode:
                break;
            case AVAudioEngineManualRenderingStatusCannotDoInCurrentContext:
                break;
            case AVAudioEngineManualRenderingStatusError:
                [sequencer stop];
                [engine stop];
                if (outError) {
                    *outError = error;
                }
                return nil;
        }
    }

    [sequencer stop];
    [engine stop];
    [QTPRenderedMIDIURLs addObject:outputURL];
    QTPLog(@"Rendered MIDI audio for QuickTime: %@", outputURL.path);
    return outputURL;
}

static NSURL *QTPRenderMIDIToAudioURL(NSURL *midiURL, NSError **outError)
{
    NSError *fluidSynthError = nil;
    NSURL *fluidSynthURL = QTPRenderMIDIWithFluidSynthToAudioURL(midiURL, &fluidSynthError);
    if (fluidSynthURL) {
        return fluidSynthURL;
    }

    if (fluidSynthError) {
        QTPLog(@"FluidSynth render failed, falling back to Apple DLS: %@", fluidSynthError.localizedDescription);
    } else {
        QTPLog(@"FluidSynth or a SoundFont was not found; falling back to Apple DLS");
    }

    return QTPRenderMIDIWithAppleDLSToAudioURL(midiURL, outError);
}

@interface NSDocumentController (QTPMIDIPlugin)
- (void)qtp_midi_openDocumentWithContentsOfURL:(NSURL *)url
                                       display:(BOOL)displayDocument
                             completionHandler:(void (^)(NSDocument *document, BOOL documentWasAlreadyOpen, NSError *error))completionHandler;
- (NSDocument *)qtp_midi_openDocumentWithContentsOfURL:(NSURL *)url
                                               display:(BOOL)displayDocument
                                                 error:(NSError **)outError;
@end

@implementation NSDocumentController (QTPMIDIPlugin)

- (void)qtp_midi_openDocumentWithContentsOfURL:(NSURL *)url
                                       display:(BOOL)displayDocument
                             completionHandler:(void (^)(NSDocument *document, BOOL documentWasAlreadyOpen, NSError *error))completionHandler
{
    if (!QTPIsMIDIURL(url)) {
        [self qtp_midi_openDocumentWithContentsOfURL:url display:displayDocument completionHandler:completionHandler];
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *audioURL = QTPRenderMIDIToAudioURL(url, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!audioURL) {
                QTPLog(@"MIDI render failed for %@: %@", url.path, error.localizedDescription);
                if (completionHandler) {
                    completionHandler(nil, NO, error);
                }
                return;
            }

            [self qtp_midi_openDocumentWithContentsOfURL:audioURL
                                                 display:displayDocument
                                       completionHandler:completionHandler];
        });
    });
}

- (NSDocument *)qtp_midi_openDocumentWithContentsOfURL:(NSURL *)url
                                               display:(BOOL)displayDocument
                                                 error:(NSError **)outError
{
    if (!QTPIsMIDIURL(url)) {
        return [self qtp_midi_openDocumentWithContentsOfURL:url display:displayDocument error:outError];
    }

    NSError *error = nil;
    NSURL *audioURL = QTPRenderMIDIToAudioURL(url, &error);
    if (!audioURL) {
        QTPLog(@"MIDI render failed for %@: %@", url.path, error.localizedDescription);
        if (outError) {
            *outError = error;
        }
        return nil;
    }

    return [self qtp_midi_openDocumentWithContentsOfURL:audioURL display:displayDocument error:outError];
}

@end

static BOOL QTPSwizzleInstanceMethod(Class targetClass, SEL originalSelector, SEL replacementSelector)
{
    Method replacementMethod = class_getInstanceMethod(NSDocumentController.class, replacementSelector);
    if (!replacementMethod) {
        return NO;
    }

    class_addMethod(targetClass,
                    replacementSelector,
                    method_getImplementation(replacementMethod),
                    method_getTypeEncoding(replacementMethod));

    Method originalMethod = class_getInstanceMethod(targetClass, originalSelector);
    Method targetReplacementMethod = class_getInstanceMethod(targetClass, replacementSelector);

    if (!originalMethod || !targetReplacementMethod) {
        return NO;
    }

    method_exchangeImplementations(originalMethod, targetReplacementMethod);
    return YES;
}

static void QTPSwizzleOpenDocumentClass(Class controllerClass)
{
    NSString *className = NSStringFromClass(controllerClass);
    if ([QTPMIDISwizzledClassNames containsObject:className]) {
        return;
    }

    NSUInteger installedCount = 0;

    if (QTPSwizzleInstanceMethod(controllerClass,
                                 @selector(openDocumentWithContentsOfURL:display:completionHandler:),
                                 @selector(qtp_midi_openDocumentWithContentsOfURL:display:completionHandler:))) {
        installedCount++;
    }

    if (QTPSwizzleInstanceMethod(controllerClass,
                                 @selector(openDocumentWithContentsOfURL:display:error:),
                                 @selector(qtp_midi_openDocumentWithContentsOfURL:display:error:))) {
        installedCount++;
    }

    if (installedCount > 0) {
        [QTPMIDISwizzledClassNames addObject:className];
        QTPLog(@"MIDI render-open handler installed on %@ (%lu hook%@)",
               className,
               installedCount,
               installedCount == 1 ? @"" : @"s");
    } else {
        QTPLog(@"No MIDI open hook was installed on %@", className);
    }
}

static void QTPSwizzleOpenDocument(void)
{
    QTPSwizzleOpenDocumentClass(NSDocumentController.class);

    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *notification) {
        QTPSwizzleOpenDocumentClass(object_getClass(NSDocumentController.sharedDocumentController));
    }];
}

void QTPPluginMain(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        QTPMIDISwizzledClassNames = [NSMutableSet set];
        QTPRenderedMIDIURLs = [NSMutableArray array];
        QTPCleanupRenderedMIDICache();
        QTPSwizzleOpenDocument();
    });
}
