#import <AppKit/AppKit.h>

@interface QTPApplicationLauncherDelegate : NSObject <NSApplicationDelegate>
@property (nonatomic, strong) NSMutableArray<NSURL *> *pendingURLs;
@property (nonatomic, strong) NSTask *quickTimeTask;
@property (nonatomic) BOOL launched;
@end

@implementation QTPApplicationLauncherDelegate

- (instancetype)init
{
    self = [super init];
    if (self) {
        _pendingURLs = [NSMutableArray array];
    }
    return self;
}

- (NSString *)contentsDirectory
{
    return [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Contents"];
}

- (void)applicationDidFinishLaunching:(__unused NSNotification *)notification
{
    dispatch_async(dispatch_get_main_queue(), ^{
        [self launchQuickTimeIfNeeded];
    });
}

- (void)application:(__unused NSApplication *)application openURLs:(NSArray<NSURL *> *)urls
{
    [self.pendingURLs addObjectsFromArray:urls];
    if (self.launched) {
        [self launchQuickTimeIfNeeded];
    }
}

- (BOOL)application:(__unused NSApplication *)sender openFile:(NSString *)filename
{
    [self.pendingURLs addObject:[NSURL fileURLWithPath:filename]];
    if (self.launched) {
        [self launchQuickTimeIfNeeded];
    }
    return YES;
}

- (void)launchQuickTimeIfNeeded
{
    if (self.quickTimeTask.isRunning) {
        return;
    }

    self.launched = YES;

    NSString *contents = self.contentsDirectory;
    NSString *innerExecutable = [contents stringByAppendingPathComponent:@"Resources/QuickTime Player.app/Contents/MacOS/QuickTime Player"];
    NSString *pluginRoot = [contents stringByAppendingPathComponent:@"PlugIns/QuickTimePlayerPlus"];
    NSString *injector = [pluginRoot stringByAppendingPathComponent:@"QuickTimePlayerPlus.dylib"];

    NSMutableArray<NSString *> *arguments = [NSMutableArray array];
    for (NSURL *url in self.pendingURLs) {
        [arguments addObject:url.path];
    }
    [self.pendingURLs removeAllObjects];

    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:innerExecutable];
    task.arguments = arguments;

    NSMutableDictionary<NSString *, NSString *> *environment = [NSProcessInfo.processInfo.environment mutableCopy];
    environment[@"DYLD_INSERT_LIBRARIES"] = injector;
    environment[@"QTP_PLUGIN_PATH"] = pluginRoot;
    task.environment = environment;

    __weak typeof(self) weakSelf = self;
    task.terminationHandler = ^(__unused NSTask *finishedTask) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [NSApp terminate:weakSelf];
        });
    };

    NSError *error = nil;
    if (![task launchAndReturnError:&error]) {
        NSAlert *alert = [[NSAlert alloc] init];
        alert.messageText = @"QuickTime Player+ could not launch QuickTime Player.";
        alert.informativeText = error.localizedDescription ?: @"Unknown error";
        [alert runModal];
        [NSApp terminate:self];
        return;
    }

    self.quickTimeTask = task;
}

@end

int main(__unused int argc, __unused const char *argv[])
{
    @autoreleasepool {
        NSApplication *application = NSApplication.sharedApplication;
        QTPApplicationLauncherDelegate *delegate = [[QTPApplicationLauncherDelegate alloc] init];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
