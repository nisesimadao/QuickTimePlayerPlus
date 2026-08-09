#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import "QTPPlugin.h"

static NSMutableSet<NSString *> *QTPTranscodeSwizzledClassNames;
static NSMutableArray<NSURL *> *QTPTranscodedURLs;

static NSSet<NSString *> *QTPTranscodeExtensions(void)
{
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:@[@"ogg", @"oga", @"ogv", @"webm", @"mkv", @"wmv", @"wma", @"avi", @"divx", @"xvid", @"flv"]];
    });
    return extensions;
}

static BOOL QTPTranscodeHandlesURL(NSURL *url)
{
    return [QTPTranscodeExtensions() containsObject:url.pathExtension.lowercaseString];
}

static NSString *QTPFindFFmpegPath(void)
{
    NSString *configuredPath = [NSUserDefaults.standardUserDefaults stringForKey:@"QTPFFmpegPath"];
    if (configuredPath.length > 0 && [NSFileManager.defaultManager isExecutableFileAtPath:configuredPath]) {
        return configuredPath;
    }

    NSArray<NSString *> *candidates = @[
        @"/opt/homebrew/bin/ffmpeg",
        @"/usr/local/bin/ffmpeg",
        @"/usr/bin/ffmpeg"
    ];

    for (NSString *candidate in candidates) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

static NSURL *QTPTranscodeCacheDirectoryURL(void)
{
    return [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:@"QuickTimePlayerPlus/Transcode" isDirectory:YES];
}

static void QTPCleanupTranscodeCache(void)
{
    NSURL *directoryURL = QTPTranscodeCacheDirectoryURL();
    NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directoryURL
                                                            includingPropertiesForKeys:nil
                                                                               options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                                 error:nil];
    NSUInteger removedCount = 0;
    for (NSURL *url in contents) {
        if ([NSFileManager.defaultManager removeItemAtURL:url error:nil]) {
            removedCount++;
        }
    }

    if (removedCount > 0) {
        QTPLog(@"Removed %lu cached transcoded media file%@", removedCount, removedCount == 1 ? @"" : @"s");
    }
}

static BOOL QTPSourceLooksAudioOnly(NSURL *url)
{
    NSString *extension = url.pathExtension.lowercaseString;
    if ([extension isEqualToString:@"wma"] || [extension isEqualToString:@"oga"]) {
        return YES;
    }

    AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
    return [asset tracksWithMediaType:AVMediaTypeVideo].count == 0 && [asset tracksWithMediaType:AVMediaTypeAudio].count > 0;
}

static NSURL *QTPTranscodedURLForURL(NSURL *sourceURL)
{
    NSURL *directoryURL = QTPTranscodeCacheDirectoryURL();
    [NSFileManager.defaultManager createDirectoryAtURL:directoryURL
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];

    NSString *baseName = sourceURL.URLByDeletingPathExtension.lastPathComponent ?: @"Transcoded Media";
    NSString *extension = QTPSourceLooksAudioOnly(sourceURL) ? @"m4a" : @"mp4";
    NSString *fileName = [NSString stringWithFormat:@"%@-%@.%@", baseName, NSUUID.UUID.UUIDString, extension];
    return [directoryURL URLByAppendingPathComponent:fileName];
}

static NSURL *QTPTranscodeURL(NSURL *sourceURL, NSError **outError)
{
    NSString *ffmpegPath = QTPFindFFmpegPath();
    if (!ffmpegPath) {
        NSString *description = @"ffmpeg was not found at /opt/homebrew/bin/ffmpeg or /usr/local/bin/ffmpeg.";
        if (outError) {
            *outError = [NSError errorWithDomain:@"QuickTimePlayerPlus.Transcode"
                                           code:1
                                       userInfo:@{NSLocalizedDescriptionKey: description}];
        }
        return nil;
    }

    NSURL *outputURL = QTPTranscodedURLForURL(sourceURL);
    BOOL audioOnly = [outputURL.pathExtension.lowercaseString isEqualToString:@"m4a"];

    NSMutableArray<NSString *> *arguments = [NSMutableArray arrayWithArray:@[
        @"-y",
        @"-hide_banner",
        @"-loglevel", @"error",
        @"-i", sourceURL.path
    ]];

    if (audioOnly) {
        [arguments addObjectsFromArray:@[@"-vn", @"-c:a", @"aac", @"-b:a", @"192k", outputURL.path]];
    } else {
        [arguments addObjectsFromArray:@[@"-map", @"0:v:0?", @"-map", @"0:a:0?", @"-c:v", @"libx264", @"-pix_fmt", @"yuv420p", @"-c:a", @"aac", @"-movflags", @"+faststart", outputURL.path]];
    }

    QTPLog(@"Transcoding legacy media for QuickTime window: %@", sourceURL.path);

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:ffmpegPath];
    task.arguments = arguments;

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
    NSString *ffmpegError = [[NSString alloc] initWithData:errorData encoding:NSUTF8StringEncoding] ?: @"";

    if (task.terminationStatus != 0) {
        if (outError) {
            NSString *description = ffmpegError.length > 0 ? ffmpegError : @"ffmpeg failed to transcode the media.";
            *outError = [NSError errorWithDomain:@"QuickTimePlayerPlus.Transcode"
                                           code:task.terminationStatus
                                       userInfo:@{NSLocalizedDescriptionKey: description}];
        }
        return nil;
    }

    [QTPTranscodedURLs addObject:outputURL];
    QTPLog(@"Transcoded media for QuickTime: %@", outputURL.path);
    return outputURL;
}

@interface NSDocumentController (QTPTranscodePlugin)
- (void)qtp_transcode_openDocumentWithContentsOfURL:(NSURL *)url
                                            display:(BOOL)displayDocument
                                  completionHandler:(void (^)(NSDocument *document, BOOL documentWasAlreadyOpen, NSError *error))completionHandler;
- (NSDocument *)qtp_transcode_openDocumentWithContentsOfURL:(NSURL *)url
                                                    display:(BOOL)displayDocument
                                                      error:(NSError **)outError;
@end

@implementation NSDocumentController (QTPTranscodePlugin)

- (void)qtp_transcode_openDocumentWithContentsOfURL:(NSURL *)url
                                            display:(BOOL)displayDocument
                                  completionHandler:(void (^)(NSDocument *document, BOOL documentWasAlreadyOpen, NSError *error))completionHandler
{
    if (!QTPTranscodeHandlesURL(url)) {
        [self qtp_transcode_openDocumentWithContentsOfURL:url display:displayDocument completionHandler:completionHandler];
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *transcodedURL = QTPTranscodeURL(url, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!transcodedURL) {
                QTPLog(@"Legacy media transcode failed for %@: %@", url.path, error.localizedDescription);
                if (completionHandler) {
                    completionHandler(nil, NO, error);
                }
                return;
            }

            [self qtp_transcode_openDocumentWithContentsOfURL:transcodedURL
                                                      display:displayDocument
                                            completionHandler:completionHandler];
        });
    });
}

- (NSDocument *)qtp_transcode_openDocumentWithContentsOfURL:(NSURL *)url
                                                    display:(BOOL)displayDocument
                                                      error:(NSError **)outError
{
    if (!QTPTranscodeHandlesURL(url)) {
        return [self qtp_transcode_openDocumentWithContentsOfURL:url display:displayDocument error:outError];
    }

    NSError *error = nil;
    NSURL *transcodedURL = QTPTranscodeURL(url, &error);
    if (!transcodedURL) {
        QTPLog(@"Legacy media transcode failed for %@: %@", url.path, error.localizedDescription);
        if (outError) {
            *outError = error;
        }
        return nil;
    }

    return [self qtp_transcode_openDocumentWithContentsOfURL:transcodedURL display:displayDocument error:outError];
}

@end

static BOOL QTPTranscodeSwizzleInstanceMethod(Class targetClass, SEL originalSelector, SEL replacementSelector)
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

static void QTPTranscodeSwizzleOpenDocumentClass(Class controllerClass)
{
    NSString *className = NSStringFromClass(controllerClass);
    if ([QTPTranscodeSwizzledClassNames containsObject:className]) {
        return;
    }

    NSUInteger installedCount = 0;
    if (QTPTranscodeSwizzleInstanceMethod(controllerClass,
                                          @selector(openDocumentWithContentsOfURL:display:completionHandler:),
                                          @selector(qtp_transcode_openDocumentWithContentsOfURL:display:completionHandler:))) {
        installedCount++;
    }

    if (QTPTranscodeSwizzleInstanceMethod(controllerClass,
                                          @selector(openDocumentWithContentsOfURL:display:error:),
                                          @selector(qtp_transcode_openDocumentWithContentsOfURL:display:error:))) {
        installedCount++;
    }

    if (installedCount > 0) {
        [QTPTranscodeSwizzledClassNames addObject:className];
        QTPLog(@"Legacy media transcode handler installed on %@ (%lu hook%@)",
               className,
               installedCount,
               installedCount == 1 ? @"" : @"s");
    }
}

static void QTPTranscodeSwizzleOpenDocument(void)
{
    QTPTranscodeSwizzleOpenDocumentClass(NSDocumentController.class);
    [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                    object:nil
                                                     queue:NSOperationQueue.mainQueue
                                                usingBlock:^(__unused NSNotification *notification) {
        QTPTranscodeSwizzleOpenDocumentClass(object_getClass(NSDocumentController.sharedDocumentController));
    }];
}

void QTPPluginMain(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        QTPTranscodeSwizzledClassNames = [NSMutableSet set];
        QTPTranscodedURLs = [NSMutableArray array];
        QTPCleanupTranscodeCache();
        QTPTranscodeSwizzleOpenDocument();
    });
}
