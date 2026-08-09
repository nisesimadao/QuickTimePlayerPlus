#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import "QTPPlugin.h"

NSString * const QTPPluginDidLoadNotification = @"QTPPluginDidLoadNotification";

static NSString * const QTPDisabledPluginIdentifiersKey = @"QTPDisabledPluginIdentifiers";
static NSString * const QTPFFmpegPathKey = @"QTPFFmpegPath";

@interface QTPPluginManagerController : NSObject
@property (nonatomic, strong) NSWindow *window;
- (void)showWindow;
- (void)showWindowFromMenu:(id)sender;
- (void)addPlugin:(id)sender;
- (void)openPluginFolder:(id)sender;
- (void)clearCaches:(id)sender;
- (void)chooseFFmpeg:(id)sender;
@end

static QTPPluginManagerController *QTPSharedPluginManagerController;

static NSArray<NSURL *> *QTPPluginSearchURLs(void)
{
    NSMutableArray<NSURL *> *urls = [NSMutableArray array];
    NSFileManager *fileManager = NSFileManager.defaultManager;

    NSString *environmentPath = NSProcessInfo.processInfo.environment[@"QTP_PLUGIN_PATH"];
    if (environmentPath.length > 0) {
        NSArray<NSString *> *components = [environmentPath componentsSeparatedByString:@":"];
        for (NSString *component in components) {
            if (component.length > 0) {
                [urls addObject:[NSURL fileURLWithPath:component isDirectory:YES]];
            }
        }
    }

    NSURL *bundleURL = NSBundle.mainBundle.bundleURL;
    NSURL *appPluginsURL = [bundleURL URLByAppendingPathComponent:@"Contents/PlugIns/QuickTimePlayerPlus" isDirectory:YES];
    [urls addObject:appPluginsURL];

    NSURL *applicationSupportURL = [fileManager URLForDirectory:NSApplicationSupportDirectory
                                                       inDomain:NSUserDomainMask
                                              appropriateForURL:nil
                                                         create:NO
                                                          error:nil];
    if (applicationSupportURL) {
        [urls addObject:[applicationSupportURL URLByAppendingPathComponent:@"QuickTimePlayer+/PlugIns" isDirectory:YES]];
    }

    return urls;
}

static NSMutableArray<NSDictionary<NSString *, id> *> *QTPInstalledPluginInfos(void)
{
    NSFileManager *fileManager = NSFileManager.defaultManager;
    NSMutableArray<NSDictionary<NSString *, id> *> *plugins = [NSMutableArray array];
    NSMutableSet<NSString *> *seenIdentifiers = [NSMutableSet set];

    for (NSURL *directoryURL in QTPPluginSearchURLs()) {
        NSArray<NSURL *> *contents = [fileManager contentsOfDirectoryAtURL:directoryURL
                                                includingPropertiesForKeys:nil
                                                                   options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                     error:nil];
        for (NSURL *candidateURL in contents) {
            if (![candidateURL.pathExtension.lowercaseString isEqualToString:@"qtplugin"]) {
                continue;
            }

            NSBundle *bundle = [NSBundle bundleWithURL:candidateURL];
            NSString *identifier = bundle.bundleIdentifier ?: candidateURL.path;
            if ([seenIdentifiers containsObject:identifier]) {
                continue;
            }

            [seenIdentifiers addObject:identifier];
            NSDictionary *info = bundle.infoDictionary ?: @{};
            NSArray *extensions = info[@"QTPPluginSupportedExtensions"] ?: @[];
            [plugins addObject:@{
                @"identifier": identifier,
                @"name": info[@"CFBundleName"] ?: candidateURL.lastPathComponent,
                @"version": info[@"CFBundleShortVersionString"] ?: @"",
                @"description": info[@"QTPPluginDescription"] ?: @"",
                @"extensions": [extensions isKindOfClass:NSArray.class] ? extensions : @[],
                @"path": candidateURL.path
            }];
        }
    }

    [plugins sortUsingComparator:^NSComparisonResult(NSDictionary<NSString *, id> *left, NSDictionary<NSString *, id> *right) {
        return [left[@"name"] compare:right[@"name"] options:NSCaseInsensitiveSearch];
    }];
    return plugins;
}

static NSMutableSet<NSString *> *QTPDisabledPluginIdentifiers(void)
{
    NSArray<NSString *> *identifiers = [NSUserDefaults.standardUserDefaults stringArrayForKey:QTPDisabledPluginIdentifiersKey] ?: @[];
    return [NSMutableSet setWithArray:identifiers];
}

static void QTPSetPluginIdentifierEnabled(NSString *identifier, BOOL enabled)
{
    NSMutableSet<NSString *> *disabledIdentifiers = QTPDisabledPluginIdentifiers();
    if (enabled) {
        [disabledIdentifiers removeObject:identifier];
    } else {
        [disabledIdentifiers addObject:identifier];
    }

    NSArray<NSString *> *sortedIdentifiers = [disabledIdentifiers.allObjects sortedArrayUsingSelector:@selector(compare:)];
    [NSUserDefaults.standardUserDefaults setObject:sortedIdentifiers forKey:QTPDisabledPluginIdentifiersKey];
}

static NSURL *QTPUserPluginDirectoryURL(void)
{
    NSURL *applicationSupportURL = [NSFileManager.defaultManager URLForDirectory:NSApplicationSupportDirectory
                                                                        inDomain:NSUserDomainMask
                                                               appropriateForURL:nil
                                                                          create:YES
                                                                           error:nil];
    return [applicationSupportURL URLByAppendingPathComponent:@"QuickTimePlayer+/PlugIns" isDirectory:YES];
}

static void QTPLoadPluginBundleAtURL(NSURL *pluginURL, NSMutableSet<NSString *> *loadedBundleIdentifiers)
{
    CFBundleRef bundle = CFBundleCreate(kCFAllocatorDefault, (__bridge CFURLRef)pluginURL);
    if (!bundle) {
        QTPLog(@"Could not create bundle for %@", pluginURL.path);
        return;
    }

    NSString *bundleIdentifier = [(__bridge NSString *)CFBundleGetIdentifier(bundle) copy];
    if (bundleIdentifier.length > 0 && [QTPDisabledPluginIdentifiers() containsObject:bundleIdentifier]) {
        QTPLog(@"Skipping disabled plugin %@ at %@", bundleIdentifier, pluginURL.path);
        CFRelease(bundle);
        return;
    }

    if (bundleIdentifier.length > 0 && [loadedBundleIdentifiers containsObject:bundleIdentifier]) {
        QTPLog(@"Skipping already loaded plugin identifier %@ at %@", bundleIdentifier, pluginURL.path);
        CFRelease(bundle);
        return;
    }

    if (!CFBundleLoadExecutable(bundle)) {
        QTPLog(@"Could not load plugin executable at %@", pluginURL.path);
        CFRelease(bundle);
        return;
    }

    QTPPluginMainFunction mainFunction = (QTPPluginMainFunction)CFBundleGetFunctionPointerForName(bundle, CFSTR("QTPPluginMain"));
    if (!mainFunction) {
        QTPLog(@"Plugin has no QTPPluginMain symbol: %@", pluginURL.path);
        CFRelease(bundle);
        return;
    }

    QTPLog(@"Loading plugin %@", pluginURL.lastPathComponent);
    if (bundleIdentifier.length > 0) {
        [loadedBundleIdentifiers addObject:bundleIdentifier];
    }
    mainFunction();
    [NSNotificationCenter.defaultCenter postNotificationName:QTPPluginDidLoadNotification object:pluginURL];

    // Intentionally keep the CFBundle alive for the lifetime of the host process.
}

static void QTPLoadPlugins(void)
{
    NSFileManager *fileManager = NSFileManager.defaultManager;
    static NSMutableSet<NSString *> *loadedPaths;
    static NSMutableSet<NSString *> *loadedBundleIdentifiers;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        loadedPaths = [NSMutableSet set];
        loadedBundleIdentifiers = [NSMutableSet set];
    });

    for (NSURL *directoryURL in QTPPluginSearchURLs()) {
        NSArray<NSURL *> *contents = [fileManager contentsOfDirectoryAtURL:directoryURL
                                                includingPropertiesForKeys:nil
                                                                   options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                     error:nil];
        for (NSURL *candidateURL in contents) {
            if (![candidateURL.pathExtension.lowercaseString isEqualToString:@"qtplugin"]) {
                continue;
            }

            NSString *standardizedPath = candidateURL.path.stringByStandardizingPath;
            if ([loadedPaths containsObject:standardizedPath]) {
                continue;
            }

            [loadedPaths addObject:standardizedPath];
            QTPLoadPluginBundleAtURL(candidateURL, loadedBundleIdentifiers);
        }
    }
}

@implementation QTPPluginManagerController

- (void)showWindow
{
    NSMutableSet<NSString *> *disabledIdentifiers = QTPDisabledPluginIdentifiers();
    NSArray<NSDictionary<NSString *, id> *> *plugins = QTPInstalledPluginInfos();

    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 420)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"QuickTime Player Plus Plugins";
    window.releasedWhenClosed = NO;

    NSStackView *stackView = [[NSStackView alloc] initWithFrame:NSZeroRect];
    stackView.orientation = NSUserInterfaceLayoutOrientationVertical;
    stackView.alignment = NSLayoutAttributeLeading;
    stackView.spacing = 12;
    stackView.edgeInsets = NSEdgeInsetsMake(18, 18, 18, 18);
    stackView.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *message = [NSTextField labelWithString:@"Enable or disable installed plugins. Changes apply the next time QuickTime Player Plus starts."];
    message.font = [NSFont systemFontOfSize:12];
    message.textColor = NSColor.secondaryLabelColor;
    message.lineBreakMode = NSLineBreakByWordWrapping;
    message.maximumNumberOfLines = 2;
    message.translatesAutoresizingMaskIntoConstraints = NO;
    [stackView addArrangedSubview:message];
    [message.widthAnchor constraintEqualToConstant:500].active = YES;

    NSStackView *buttonRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    buttonRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    buttonRow.spacing = 8;

    NSButton *addButton = [NSButton buttonWithTitle:@"Add Plugin..." target:self action:@selector(addPlugin:)];
    NSButton *folderButton = [NSButton buttonWithTitle:@"Open Plugin Folder" target:self action:@selector(openPluginFolder:)];
    NSButton *cacheButton = [NSButton buttonWithTitle:@"Clear Render Caches" target:self action:@selector(clearCaches:)];
    NSButton *ffmpegButton = [NSButton buttonWithTitle:@"Set ffmpeg..." target:self action:@selector(chooseFFmpeg:)];
    for (NSButton *button in @[addButton, folderButton, cacheButton, ffmpegButton]) {
        button.bezelStyle = NSBezelStyleRounded;
        [buttonRow addArrangedSubview:button];
    }
    [stackView addArrangedSubview:buttonRow];

    NSString *ffmpegPath = [NSUserDefaults.standardUserDefaults stringForKey:QTPFFmpegPathKey];
    NSTextField *ffmpegLabel = [NSTextField labelWithString:ffmpegPath.length > 0 ? [NSString stringWithFormat:@"ffmpeg: %@", ffmpegPath] : @"ffmpeg: auto-detect (/opt/homebrew/bin/ffmpeg, /usr/local/bin/ffmpeg)"];
    ffmpegLabel.font = [NSFont systemFontOfSize:12];
    ffmpegLabel.textColor = NSColor.secondaryLabelColor;
    ffmpegLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    ffmpegLabel.translatesAutoresizingMaskIntoConstraints = NO;
    [stackView addArrangedSubview:ffmpegLabel];
    [ffmpegLabel.widthAnchor constraintEqualToConstant:500].active = YES;

    for (NSDictionary<NSString *, id> *plugin in plugins) {
        NSString *identifier = plugin[@"identifier"];
        NSButton *checkbox = [NSButton checkboxWithTitle:plugin[@"name"] target:self action:@selector(togglePlugin:)];
        checkbox.identifier = identifier;
        checkbox.state = [disabledIdentifiers containsObject:identifier] ? NSControlStateValueOff : NSControlStateValueOn;
        checkbox.font = [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold];
        [stackView addArrangedSubview:checkbox];

        NSArray<NSString *> *extensions = plugin[@"extensions"];
        NSString *extensionText = extensions.count > 0 ? [NSString stringWithFormat:@"Extensions: %@", [extensions componentsJoinedByString:@", "]] : @"";
        NSString *detailText = [@[plugin[@"description"], extensionText] componentsJoinedByString:@"\n"];
        NSTextField *detail = [NSTextField labelWithString:detailText];
        detail.font = [NSFont systemFontOfSize:12];
        detail.textColor = NSColor.secondaryLabelColor;
        detail.lineBreakMode = NSLineBreakByWordWrapping;
        detail.maximumNumberOfLines = 4;
        detail.translatesAutoresizingMaskIntoConstraints = NO;
        [stackView addArrangedSubview:detail];
        [detail.widthAnchor constraintEqualToConstant:500].active = YES;
    }

    if (plugins.count == 0) {
        NSTextField *empty = [NSTextField labelWithString:@"No .qtplugin bundles were found."];
        empty.textColor = NSColor.secondaryLabelColor;
        [stackView addArrangedSubview:empty];
    }

    NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    scrollView.documentView = stackView;
    scrollView.hasVerticalScroller = YES;
    scrollView.translatesAutoresizingMaskIntoConstraints = NO;
    window.contentView = scrollView;

    [NSLayoutConstraint activateConstraints:@[
        [stackView.widthAnchor constraintEqualToAnchor:scrollView.contentView.widthAnchor],
    ]];

    self.window = window;
    [window center];
    [window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)togglePlugin:(NSButton *)sender
{
    QTPSetPluginIdentifierEnabled(sender.identifier, sender.state == NSControlStateValueOn);
}

- (void)showWindowFromMenu:(__unused id)sender
{
    [self showWindow];
}

- (void)addPlugin:(__unused id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = NO;
    panel.canChooseDirectories = YES;
    panel.allowsMultipleSelection = YES;
    panel.prompt = @"Add";
    panel.message = @"Choose .qtplugin bundles to copy into the user plugin folder.";

    if ([panel runModal] != NSModalResponseOK) {
        return;
    }

    NSURL *destinationDirectory = QTPUserPluginDirectoryURL();
    [NSFileManager.defaultManager createDirectoryAtURL:destinationDirectory
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];

    for (NSURL *sourceURL in panel.URLs) {
        if (![sourceURL.pathExtension.lowercaseString isEqualToString:@"qtplugin"]) {
            continue;
        }

        NSURL *destinationURL = [destinationDirectory URLByAppendingPathComponent:sourceURL.lastPathComponent isDirectory:YES];
        if ([NSFileManager.defaultManager fileExistsAtPath:destinationURL.path]) {
            [NSFileManager.defaultManager removeItemAtURL:destinationURL error:nil];
        }
        [NSFileManager.defaultManager copyItemAtURL:sourceURL toURL:destinationURL error:nil];
    }

    [self showWindow];
}

- (void)openPluginFolder:(__unused id)sender
{
    NSURL *directoryURL = QTPUserPluginDirectoryURL();
    [NSFileManager.defaultManager createDirectoryAtURL:directoryURL
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    [NSWorkspace.sharedWorkspace openURL:directoryURL];
}

- (void)clearCaches:(__unused id)sender
{
    NSURL *rootURL = [[NSURL fileURLWithPath:NSTemporaryDirectory() isDirectory:YES]
        URLByAppendingPathComponent:@"QuickTimePlayerPlus" isDirectory:YES];
    [NSFileManager.defaultManager removeItemAtURL:rootURL error:nil];
    [self showWindow];
}

- (void)chooseFFmpeg:(__unused id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Use";
    panel.message = @"Choose the ffmpeg executable used by the legacy media transcode plugin.";

    if ([panel runModal] == NSModalResponseOK) {
        [NSUserDefaults.standardUserDefaults setObject:panel.URL.path forKey:QTPFFmpegPathKey];
        [self showWindow];
    }
}

@end

static void QTPInstallPluginManagerMenuItem(void)
{
    if (!QTPSharedPluginManagerController) {
        QTPSharedPluginManagerController = [[QTPPluginManagerController alloc] init];
    }

    NSMenuItem *appMenuItem = NSApp.mainMenu.itemArray.firstObject;
    NSMenu *appMenu = appMenuItem.submenu;
    if (!appMenu) {
        return;
    }

    for (NSMenuItem *item in appMenu.itemArray) {
        if ([item.title isEqualToString:@"QuickTime Player Plus Plugins..."]) {
            return;
        }
    }

    [appMenu addItem:[NSMenuItem separatorItem]];
    NSMenuItem *managerItem = [[NSMenuItem alloc] initWithTitle:@"QuickTime Player Plus Plugins..."
                                                         action:@selector(showWindowFromMenu:)
                                                  keyEquivalent:@","];
    managerItem.target = QTPSharedPluginManagerController;
    [appMenu addItem:managerItem];
}

__attribute__((constructor))
static void QTPInjectorConstructor(void)
{
    @autoreleasepool {
        NSString *bundleIdentifier = NSBundle.mainBundle.bundleIdentifier ?: @"";
        if (![bundleIdentifier isEqualToString:@"com.apple.QuickTimePlayerX"] &&
            ![bundleIdentifier isEqualToString:@"local.quicktimeplayerplus.Player"]) {
            QTPLog(@"Loaded into %@; skipping QuickTime-only plugin bootstrap", bundleIdentifier);
            return;
        }

        QTPLog(@"Injector loaded into %@", NSBundle.mainBundle.bundlePath);
        QTPLoadPlugins();

        [NSNotificationCenter.defaultCenter addObserverForName:NSApplicationDidFinishLaunchingNotification
                                                        object:nil
                                                         queue:NSOperationQueue.mainQueue
                                                    usingBlock:^(__unused NSNotification *notification) {
            QTPLoadPlugins();
            QTPInstallPluginManagerMenuItem();
        }];
    }
}
