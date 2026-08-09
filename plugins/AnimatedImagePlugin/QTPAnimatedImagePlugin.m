#import <AppKit/AppKit.h>
#import <objc/runtime.h>
#import "QTPPlugin.h"

static NSMutableSet<NSString *> *QTPAnimatedImageSwizzledClassNames;
static NSMutableArray<NSURL *> *QTPAnimatedImageURLs;

static BOOL QTPAnimatedImageHandlesURL(NSURL *url)
{
    static NSSet<NSString *> *extensions;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        extensions = [NSSet setWithArray:@[@"gif", @"webp", @"avif", @"apng"]];
    });
    return [extensions containsObject:url.pathExtension.lowercaseString];
}

static NSString *QTPAnimatedImageFindFFmpegPath(void)
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

static NSURL *QTPAnimatedImageOutputURL(NSURL *sourceURL)
{
    NSURL *directoryURL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:@"QuickTimePlayerPlus/AnimatedImage" isDirectory:YES];
    [NSFileManager.defaultManager createDirectoryAtURL:directoryURL withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *baseName = sourceURL.URLByDeletingPathExtension.lastPathComponent ?: @"Animated Image";
    return [directoryURL URLByAppendingPathComponent:[NSString stringWithFormat:@"%@-%@.mp4", baseName, NSUUID.UUID.UUIDString]];
}

static void QTPAnimatedImageCleanupCache(void)
{
    NSURL *directoryURL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:@"QuickTimePlayerPlus/AnimatedImage" isDirectory:YES];
    NSUInteger removedCount = 0;
    for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:directoryURL includingPropertiesForKeys:nil options:NSDirectoryEnumerationSkipsHiddenFiles error:nil]) {
        if ([NSFileManager.defaultManager removeItemAtURL:url error:nil]) {
            removedCount++;
        }
    }
    if (removedCount > 0) {
        QTPLog(@"Removed %lu cached animated image render%@", removedCount, removedCount == 1 ? @"" : @"s");
    }
}

static NSURL *QTPAnimatedImageRenderURL(NSURL *sourceURL, NSError **outError)
{
    NSString *ffmpegPath = QTPAnimatedImageFindFFmpegPath();
    if (!ffmpegPath) {
        if (outError) {
            *outError = [NSError errorWithDomain:@"QuickTimePlayerPlus.AnimatedImage" code:1 userInfo:@{NSLocalizedDescriptionKey: @"ffmpeg was not found."}];
        }
        return nil;
    }

    NSURL *outputURL = QTPAnimatedImageOutputURL(sourceURL);
    QTPLog(@"Rendering animated image for QuickTime: %@", sourceURL.path);

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:ffmpegPath];
    task.arguments = @[
        @"-y", @"-hide_banner", @"-loglevel", @"error",
        @"-i", sourceURL.path,
        @"-movflags", @"+faststart",
        @"-pix_fmt", @"yuv420p",
        @"-vf", @"fps=30,scale=trunc(iw/2)*2:trunc(ih/2)*2",
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
            *outError = [NSError errorWithDomain:@"QuickTimePlayerPlus.AnimatedImage"
                                           code:task.terminationStatus
                                       userInfo:@{NSLocalizedDescriptionKey: ffmpegError.length > 0 ? ffmpegError : @"ffmpeg failed."}];
        }
        return nil;
    }

    [QTPAnimatedImageURLs addObject:outputURL];
    QTPLog(@"Rendered animated image for QuickTime: %@", outputURL.path);
    return outputURL;
}

@interface NSDocumentController (QTPAnimatedImagePlugin)
- (void)qtp_animated_openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)displayDocument completionHandler:(void (^)(NSDocument *document, BOOL documentWasAlreadyOpen, NSError *error))completionHandler;
- (NSDocument *)qtp_animated_openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)displayDocument error:(NSError **)outError;
@end

@implementation NSDocumentController (QTPAnimatedImagePlugin)

- (void)qtp_animated_openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)displayDocument completionHandler:(void (^)(NSDocument *document, BOOL documentWasAlreadyOpen, NSError *error))completionHandler
{
    if (!QTPAnimatedImageHandlesURL(url)) {
        [self qtp_animated_openDocumentWithContentsOfURL:url display:displayDocument completionHandler:completionHandler];
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSError *error = nil;
        NSURL *renderedURL = QTPAnimatedImageRenderURL(url, &error);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!renderedURL) {
                QTPLog(@"Animated image render failed for %@: %@", url.path, error.localizedDescription);
                if (completionHandler) {
                    completionHandler(nil, NO, error);
                }
                return;
            }
            [self qtp_animated_openDocumentWithContentsOfURL:renderedURL display:displayDocument completionHandler:completionHandler];
        });
    });
}

- (NSDocument *)qtp_animated_openDocumentWithContentsOfURL:(NSURL *)url display:(BOOL)displayDocument error:(NSError **)outError
{
    if (!QTPAnimatedImageHandlesURL(url)) {
        return [self qtp_animated_openDocumentWithContentsOfURL:url display:displayDocument error:outError];
    }
    NSURL *renderedURL = QTPAnimatedImageRenderURL(url, outError);
    return renderedURL ? [self qtp_animated_openDocumentWithContentsOfURL:renderedURL display:displayDocument error:outError] : nil;
}

@end

static BOOL QTPAnimatedImageSwizzle(Class targetClass, SEL originalSelector, SEL replacementSelector)
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

static void QTPAnimatedImageSwizzleClass(Class controllerClass)
{
    NSString *className = NSStringFromClass(controllerClass);
    if ([QTPAnimatedImageSwizzledClassNames containsObject:className]) {
        return;
    }
    NSUInteger count = 0;
    if (QTPAnimatedImageSwizzle(controllerClass, @selector(openDocumentWithContentsOfURL:display:completionHandler:), @selector(qtp_animated_openDocumentWithContentsOfURL:display:completionHandler:))) {
        count++;
    }
    if (QTPAnimatedImageSwizzle(controllerClass, @selector(openDocumentWithContentsOfURL:display:error:), @selector(qtp_animated_openDocumentWithContentsOfURL:display:error:))) {
        count++;
    }
    if (count > 0) {
        [QTPAnimatedImageSwizzledClassNames addObject:className];
        QTPLog(@"Animated image handler installed on %@ (%lu hook%@)", className, count, count == 1 ? @"" : @"s");
    }
}

void QTPPluginMain(void)
{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        QTPAnimatedImageSwizzledClassNames = [NSMutableSet set];
        QTPAnimatedImageURLs = [NSMutableArray array];
        QTPAnimatedImageCleanupCache();
        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(__unused NSNotification *notification) {
            QTPAnimatedImageSwizzleClass(object_getClass(NSDocumentController.sharedDocumentController));
        }];
    });
}
