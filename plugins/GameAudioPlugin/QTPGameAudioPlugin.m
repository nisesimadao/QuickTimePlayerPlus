#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "QTPPlugin.h"

static NSMutableSet<NSString *> *QTPGameAudioSwizzledClassNames;
static NSMutableArray<NSURL *> *QTPGameAudioURLs;

static BOOL QTPGameAudioHandlesURL(NSURL *url)
{
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:@[@"vgm", @"vgz", @"nsf", @"spc", @"psf", @"psf2", @"minipsf", @"minipsf2", @"gym", @"ay", @"gbs", @"hes", @"kss"]];
    });
    return [extensions containsObject:url.pathExtension.lowercaseString];
}

static NSString *QTPGameAudioFindFFmpegPath(void)
{
    NSString *configuredPath = [NSUserDefaults.standardUserDefaults stringForKey:@"QTPFFmpegPath"];
    if (configuredPath.length > 0 && [NSFileManager.defaultManager isExecutableFileAtPath:configuredPath]) {
        return configuredPath;
    }
    for (NSString *path in @[@"/opt/homebrew/bin/ffmpeg", @"/usr/local/bin/ffmpeg"]) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:path]) {
            return path;
        }
    }
    return nil;
}

static NSURL *QTPGameAudioOutputURL(NSURL *sourceURL)
{
    NSURL *directoryURL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:@"QuickTimePlayerPlus/GameAudio" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *baseName = sourceURL.URLByDeletingPathExtension.lastPathComponent ?: @"Game Audio";
    return [directoryURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.m4a", baseName, NSUUID.UUID.UUIDString]];
}

static void QTPGameAudioCleanupCache(void)
{
    NSURL *directoryURL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:@"QuickTimePlayerPlus/GameAudio" isDirectory:YES];
    NSUInteger removedCount = 0;
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:directoryURL includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
        if ([NSFileManager.defaultManager removeItemAtURL:url error:nil]) {
            removedCount++;
        }
    }
    if (removedCount > 0) {
        QTPLog(@"Removed %lu cached game audio render%@", removedCount, removedCount == 1 ? @"" : @"s");
    }
}

static NSURL *QTPGameAudioRenderURL(NSURL *sourceURL, NSError **outError)
{
    NSString *ffmpegPath = QTPGameAudioFindFFmpegPath();
    if (!ffmpegPath) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"QuickTimePlayerPlus.GameAudio" code:1 userInfo:@{NSLocalizedDescriptionKey: @"ffmpeg was not found."}];
        }
        return nil;
    }

    NSURL *outputURL = QTPGameAudioOutputURL(sourceURL);
    QTPLog(@"Rendering game audio for QuickTime: %@", sourceURL.path);

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:ffmpegPath];
    task.arguments = @[
        @"-y", @"-hide_banner", @"-loglevel", @"error",
        @"-i", sourceURL.path,
        @"-t", @"300",
        @"-vn",
        @"-c:a", @"aac",
        @"-b:a", @"192k",
        outputURL.path
    ];
    NSPipe *errorPipe = [NSPipe pipe];
    task.standardError = errorPipe;

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        if (outError) {
            *outError = error;
        }
        return nil;
    }
    [task waitUntilExit];

    NSData *errorData = [errorPipe.fileHandleForReading readDataToEndOfFile];
    NSString *ffmpegError = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding] ?: @"";
    if (task.terminationStatus != 0) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"QuickTimePlayerPlus.GameAudio"
                                           code:task.terminationStatus
                                       userInfo:@{NSLocalizedDescriptionKey: ffmpegError.length > 0 ? ffmpegError : @"ffmpeg failed. This ffmpeg build may not include a game music decoder."}];
        }
        return nil;
    }

    [QTPGameAudioURLs addObject:outputURL];
    QTPLog(@"Rendered game audio for QuickTime: %@", outputURL.path);
    return outputURL;
}

@interface NSDocumentController (QTPGameAudioPlugin)
- (void)qtp_game_openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)displayDocument completionHandler:(void (^)(NSDocument *document, BOOL documentWasAlreadyOpen, NSError *error))completionHandler;
- (NSDocument *)qtp_game_openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)displayDocument error:(NSError **)outError;
@end

@implementation NSDocumentController (QTPGameAudioPlugin)

- (void)qtp_game_openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)displayDocument completionHandler:(void (^)(NSDocument *document, BOOL documentWasAlreadyOpen, NSError *error))completionHandler
{
    if (!QTPGameAudioHandlesURL(url)) {
        [self qtp_game_openDocumentWithContentsOfURL:url display:displayDocument completionHandler:completionHandler];
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *renderedURL = QTPGameAudioRenderURL(url, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!renderedURL) {
                QTPLog(@"Game audio render failed for %@: %@", url.path, error.localizedDescription);
                if (completionHandler) {
                    completionHandler(nil, NO, error);
                }
                return;
            }
            [self qtp_game_openDocumentWithContentsOfURL:renderedURL display:displayDocument completionHandler:completionHandler];
        });
    });
}

- (NSDocument *)qtp_game_openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)displayDocument error:(NSError **)outError
{
    if (!QTPGameAudioHandlesURL(url)) {
        return [self qtp_game_openDocumentWithContentsOfURL:url display:displayDocument error:outError];
    }
    NSURL *renderedURL = QTPGameAudioRenderURL(url, outError);
    return renderedURL ? [self qtp_game_openDocumentWithContentsOfURL:renderedURL display:displayDocument error:outError] : nil;
}

@end

static BOOL QTPGameAudioSwizzle(Class targetClass, SEL originalSelector, SEL replacementSelector)
{
    Method replacementMethod = class_getInstanceMethod(NSDocumentController.class, replacementSelector);
    class_addMethod(targetClass, replacementSelector, method_getImplementation(replacementMethod), method_getTypeEncoding(replacementMethod));
    Method originalMethod = class_getInstanceMethod(targetClass, originalSelector);
    Method targetReplacementMethod = class_getInstanceMethod(targetClass, replacementSelector);
    if (!originalMethod || !targetReplacementMethod) {
        return NO;
    }
    method_exchangeImplementations(originalMethod, targetReplacementMethod);
    return YES;
}

static void QTPGameAudioSwizzleClass(Class controllerClass)
{
    NSString *className = NSStringFromClass(controllerClass);
    if ([QTPGameAudioSwizzledClassNames containsObject:className]) {
        return;
    }
    NSUInteger count = 0;
    if (QTPGameAudioSwizzle(controllerClass, @selector(openDocumentWithContentsOfURL:display:completionHandler:), @selector(qtp_game_openDocumentWithContentsOfURL:display:completionHandler:))) {
        count++;
    }
    if (QTPGameAudioSwizzle(controllerClass, @selector(openDocumentWithContentsOfURL:display:error:), @selector(qtp_game_openDocumentWithContentsOfURL:display:error:))) {
        count++;
    }
    if (count > 0) {
        [QTPGameAudioSwizzledClassNames addObject:className];
        QTPLog(@"Game audio handler installed on %@ (%lu hook%@)", className, count, count == 1 ? @"" : @"s");
    }
}

void QTPPluginMain(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        QTPGameAudioSwizzledClassNames = [NSMutableSet set];
        QTPGameAudioURLs = [NSMutableArray array];
        QTPGameAudioCleanupCache();
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
            QTPGameAudioSwizzleClass(object_getClass(NSDocumentController.sharedDocumentController));
        }];
    });
}
