#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "QTPPlugin.h"

static NSMutableSet<NSString *> *QTPImageSequenceSwizzledClassNames;
static NSMutableArray<NSURL *> *QTPImageSequenceURLs;

static NSSet<NSString *> *QTPImageSequenceExtensions(void)
{
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:@[@"png", @"jpg", @"jpeg", @"tif", @"tiff", @"exr", @"dpx"]];
    });
    return extensions;
}

static BOOL QTPImageSequenceIsDirectory(NSURL *url)
{
    NSNumber *isDirectory = nil;
    [url getResourceValue:&isDirectory forKey:NSURLIsDirectoryKey error:nil];
    return isDirectory.boolValue;
}

static BOOL QTPImageSequenceHandlesURL(NSURL *url)
{
    if (QTPImageSequenceIsDirectory(url)) {
        return YES;
    }
    return [QTPImageSequenceExtensions() containsObject:url.pathExtension.lowercaseString];
}

static NSString *QTPImageSequenceFindFFmpegPath(void)
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

static NSURL *QTPImageSequenceFirstFrameInDirectory(NSURL *directoryURL)
{
    NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:directoryURL includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil];
    NSArray<NSURL *> *sorted = [contents sortedArrayUsingComparator:^NSComparisonResult(NSURL *left, NSURL *right) {
        return [left.lastPathComponent compare:right.lastPathComponent options:NSCaseInsensitiveSearch | NSNumericSearch];
    }];
    for (NSURL *url in sorted) {
        if ([QTPImageSequenceExtensions() containsObject:url.pathExtension.lowercaseString]) {
            return url;
        }
    }
    return nil;
}

static NSString *QTPImageSequencePatternForFrameURL(NSURL *frameURL)
{
    NSString *filename = frameURL.lastPathComponent;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"^(.*?)(\\d+)(\\.[^.]+)$" options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:filename options:0 range:NSMakeRange(0, filename.length)];
    if (!match || match.numberOfRanges < 4) {
        return nil;
    }

    NSString *prefix = [filename substringWithRange:[match rangeAtIndex:1]];
    NSString *digits = [filename substringWithRange:[match rangeAtIndex:2]];
    NSString *suffix = [filename substringWithRange:[match rangeAtIndex:3]];
    NSString *patternName = [NSString stringWithFormat:@"%@%%0%lud%@", prefix, digits.length, suffix];
    return [frameURL.URLByDeletingLastPathComponent.path stringByAppendingPathComponent:patternName];
}

static NSURL *QTPImageSequenceOutputURL(NSURL *sourceURL)
{
    NSURL *directoryURL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:@"QuickTimePlayerPlus/ImageSequence" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *baseName = sourceURL.URLByDeletingPathExtension.lastPathComponent ?: @"Image Sequence";
    return [directoryURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.mp4", baseName, NSUUID.UUID.UUIDString]];
}

static void QTPImageSequenceCleanupCache(void)
{
    NSURL *directoryURL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:@"QuickTimePlayerPlus/ImageSequence" isDirectory:YES];
    NSUInteger removedCount = 0;
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:directoryURL includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
        if ([NSFileManager.defaultManager removeItemAtURL:url error:nil]) {
            removedCount++;
        }
    }
    if (removedCount > 0) {
        QTPLog(@"Removed %lu cached image sequence render%@", removedCount, removedCount == 1 ? @"" : @"s");
    }
}

static NSURL *QTPImageSequenceRenderURL(NSURL *sourceURL, NSError **outError)
{
    NSString *ffmpegPath = QTPImageSequenceFindFFmpegPath();
    if (!ffmpegPath) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"QuickTimePlayerPlus.ImageSequence" code:1 userInfo:@{NSLocalizedDescriptionKey: @"ffmpeg was not found."}];
        }
        return nil;
    }

    NSURL *frameURL = QTPImageSequenceIsDirectory(sourceURL) ? QTPImageSequenceFirstFrameInDirectory(sourceURL) : sourceURL;
    NSString *pattern = frameURL ? QTPImageSequencePatternForFrameURL(frameURL) : nil;
    if (!pattern) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"QuickTimePlayerPlus.ImageSequence" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Could not infer an image sequence pattern. Use numbered names such as frame_0001.png."}];
        }
        return nil;
    }

    NSURL *outputURL = QTPImageSequenceOutputURL(sourceURL);
    QTPLog(@"Rendering image sequence for QuickTime: %@", pattern);

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:ffmpegPath];
    task.arguments = @[
        @"-y", @"-hide_banner", @"-loglevel", @"error",
        @"-framerate", @"30",
        @"-i", pattern,
        @"-movflags", @"+faststart",
        @"-pix_fmt", @"yuv420p",
        @"-c:v", @"libx264",
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
            *outError = [NSError errorWithDomain:@"QuickTimePlayerPlus.ImageSequence"
                                           code:task.terminationStatus
                                       userInfo:@{NSLocalizedDescriptionKey: ffmpegError.length > 0 ? ffmpegError : @"ffmpeg failed."}];
        }
        return nil;
    }

    [QTPImageSequenceURLs addObject:outputURL];
    QTPLog(@"Rendered image sequence for QuickTime: %@", outputURL.path);
    return outputURL;
}

@interface NSDocumentController (QTPImageSequencePlugin)
- (void)qtp_sequence_openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)displayDocument completionHandler:(void (^)(NSDocument *document, BOOL documentWasAlreadyOpen, NSError *error))completionHandler;
- (NSDocument *)qtp_sequence_openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)displayDocument error:(NSError **)outError;
@end

@implementation NSDocumentController (QTPImageSequencePlugin)

- (void)qtp_sequence_openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)displayDocument completionHandler:(void (^)(NSDocument *document, BOOL documentWasAlreadyOpen, NSError *error))completionHandler
{
    if (!QTPImageSequenceHandlesURL(url)) {
        [self qtp_sequence_openDocumentWithContentsOfURL:url display:displayDocument completionHandler:completionHandler];
        return;
    }
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *renderedURL = QTPImageSequenceRenderURL(url, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!renderedURL) {
                QTPLog(@"Image sequence render failed for %@: %@", url.path, error.localizedDescription);
                if (completionHandler) {
                    completionHandler(nil, NO, error);
                }
                return;
            }
            [self qtp_sequence_openDocumentWithContentsOfURL:renderedURL display:displayDocument completionHandler:completionHandler];
        });
    });
}

- (NSDocument *)qtp_sequence_openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)displayDocument error:(NSError **)outError
{
    if (!QTPImageSequenceHandlesURL(url)) {
        return [self qtp_sequence_openDocumentWithContentsOfURL:url display:displayDocument error:outError];
    }
    NSURL *renderedURL = QTPImageSequenceRenderURL(url, outError);
    return renderedURL ? [self qtp_sequence_openDocumentWithContentsOfURL:renderedURL display:displayDocument error:outError] : nil;
}

@end

static BOOL QTPImageSequenceSwizzle(Class targetClass, SEL originalSelector, SEL replacementSelector)
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

static void QTPImageSequenceSwizzleClass(Class controllerClass)
{
    NSString *className = NSStringFromClass(controllerClass);
    if ([QTPImageSequenceSwizzledClassNames containsObject:className]) {
        return;
    }
    NSUInteger count = 0;
    if (QTPImageSequenceSwizzle(controllerClass, @selector(openDocumentWithContentsOfURL:display:completionHandler:), @selector(qtp_sequence_openDocumentWithContentsOfURL:display:completionHandler:))) {
        count++;
    }
    if (QTPImageSequenceSwizzle(controllerClass, @selector(openDocumentWithContentsOfURL:display:error:), @selector(qtp_sequence_openDocumentWithContentsOfURL:display:error:))) {
        count++;
    }
    if (count > 0) {
        [QTPImageSequenceSwizzledClassNames addObject:className];
        QTPLog(@"Image sequence handler installed on %@ (%lu hook%@)", className, count, count == 1 ? @"" : @"s");
    }
}

void QTPPluginMain(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        QTPImageSequenceSwizzledClassNames = [NSMutableSet set];
        QTPImageSequenceURLs = [NSMutableArray array];
        QTPImageSequenceCleanupCache();
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
            QTPImageSequenceSwizzleClass(object_getClass(NSDocumentController.sharedDocumentController));
        }];
    });
}
