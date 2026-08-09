#import <AppKit/AppKit.h>
#import <CoreFoundation/CoreFoundation.h>
#import "QTPPlugin.h"

NSString * const QTPPluginDidLoadNotification = @"QTPPluginDidLoadNotification";

static NSString * const QTPDisabledPluginIdentifiersKey = @"QTPDisabledPluginIdentifiers";
static NSString * const QTPFFmpegPathKey = @"QTPFFmpegPath";
static NSString * const QTPFluidSynthPathKey = @"QTPFluidSynthPath";
static NSString * const QTPMIDISoundFontPathKey = @"QTPMIDISoundFontPath";

@interface QTPPluginManagerController : NSObject
@property (nonatomic, strong) NSWindow *window;
- (void)showWindow;
- (void)showWindowFromMenu:(id)sender;
- (void)addPlugin:(id)sender;
- (void)openPluginFolder:(id)sender;
- (void)clearCaches:(id)sender;
- (void)chooseFFmpeg:(id)sender;
- (void)chooseFluidSynth:(id)sender;
- (void)chooseMIDISoundFont:(id)sender;
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

    NSURL *systemSupportURL = [fileManager URLForDirectory:NSApplicationSupportDirectory
                                                  inDomain:NSLocalDomainMask
                                         appropriateForURL:nil
                                                    create:NO
                                                     error:nil];
    if (systemSupportURL) {
        [urls addObject:[systemSupportURL URLByAppendingPathComponent:@"QuickTimePlayerPlus/PlugIns" isDirectory:YES]];
    }

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

static NSTextField *QTPLabel(NSString *text, NSFont *font, NSColor *color)
{
    NSTextField *label = [NSTextField labelWithString:text ?: @""];
    label.font = font;
    label.textColor = color;
    label.lineBreakMode = NSLineBreakByWordWrapping;
    label.maximumNumberOfLines = 0;
    label.translatesAutoresizingMaskIntoConstraints = NO;
    return label;
}

static NSButton *QTPActionButton(NSString *title, id target, SEL action)
{
    NSButton *button = [NSButton buttonWithTitle:title target:target action:action];
    button.bezelStyle = NSBezelStyleRounded;
    button.controlSize = NSControlSizeRegular;
    button.translatesAutoresizingMaskIntoConstraints = NO;
    [button.heightAnchor constraintGreaterThanOrEqualToConstant:30].active = YES;
    return button;
}

static NSView *QTPSeparator(void)
{
    NSBox *separator = [[NSBox alloc] initWithFrame:NSZeroRect];
    separator.boxType = NSBoxSeparator;
    separator.translatesAutoresizingMaskIntoConstraints = NO;
    return separator;
}

static NSView *QTPPathRow(NSString *title, NSString *value, NSString *fallback, NSButton *button)
{
    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 12;
    row.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *labels = [[NSStackView alloc] initWithFrame:NSZeroRect];
    labels.orientation = NSUserInterfaceLayoutOrientationVertical;
    labels.alignment = NSLayoutAttributeLeading;
    labels.spacing = 2;
    labels.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *titleLabel = QTPLabel(title, [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold], NSColor.labelColor);
    NSString *displayValue = value.length > 0 ? value : fallback;
    NSTextField *valueLabel = QTPLabel(displayValue, [NSFont systemFontOfSize:NSFont.smallSystemFontSize], NSColor.secondaryLabelColor);
    valueLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    valueLabel.maximumNumberOfLines = 1;
    [labels addArrangedSubview:titleLabel];
    [labels addArrangedSubview:valueLabel];

    [row addArrangedSubview:labels];
    [row addArrangedSubview:button];
    [labels setContentHuggingPriority:NSLayoutPriorityDefaultLow forOrientation:NSLayoutConstraintOrientationHorizontal];
    [button setContentHuggingPriority:NSLayoutPriorityRequired forOrientation:NSLayoutConstraintOrientationHorizontal];
    return row;
}

@implementation QTPPluginManagerController

- (void)showWindow
{
    [self.window close];

    NSMutableSet<NSString *> *disabledIdentifiers = QTPDisabledPluginIdentifiers();
    NSArray<NSDictionary<NSString *, id> *> *plugins = QTPInstalledPluginInfos();

    NSWindow *window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 860, 580)
                                                   styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
                                                     backing:NSBackingStoreBuffered
                                                       defer:NO];
    window.title = @"Plugin Manager";
    window.minSize = NSMakeSize(760, 500);
    window.releasedWhenClosed = NO;

    NSView *contentView = [[NSView alloc] initWithFrame:NSZeroRect];
    contentView.translatesAutoresizingMaskIntoConstraints = NO;
    window.contentView = contentView;

    NSStackView *rootStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    rootStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    rootStack.alignment = NSLayoutAttributeLeading;
    rootStack.spacing = 18;
    rootStack.edgeInsets = NSEdgeInsetsMake(22, 24, 24, 24);
    rootStack.translatesAutoresizingMaskIntoConstraints = NO;
    [contentView addSubview:rootStack];

    NSTextField *titleLabel = QTPLabel(@"QuickTime Player Plus", [NSFont systemFontOfSize:22 weight:NSFontWeightSemibold], NSColor.labelColor);
    NSTextField *subtitleLabel = QTPLabel(@"Manage installed plugins, renderer paths, and temporary render caches.", [NSFont systemFontOfSize:NSFont.systemFontSize], NSColor.secondaryLabelColor);
    subtitleLabel.maximumNumberOfLines = 1;
    NSStackView *headerStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    headerStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    headerStack.alignment = NSLayoutAttributeLeading;
    headerStack.spacing = 3;
    headerStack.translatesAutoresizingMaskIntoConstraints = NO;
    [headerStack addArrangedSubview:titleLabel];
    [headerStack addArrangedSubview:subtitleLabel];
    [rootStack addArrangedSubview:headerStack];

    NSStackView *mainStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
    mainStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    mainStack.alignment = NSLayoutAttributeTop;
    mainStack.spacing = 22;
    mainStack.translatesAutoresizingMaskIntoConstraints = NO;
    [rootStack addArrangedSubview:mainStack];

    NSStackView *pluginColumn = [[NSStackView alloc] initWithFrame:NSZeroRect];
    pluginColumn.orientation = NSUserInterfaceLayoutOrientationVertical;
    pluginColumn.alignment = NSLayoutAttributeLeading;
    pluginColumn.spacing = 12;
    pluginColumn.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *pluginHeaderRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    pluginHeaderRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    pluginHeaderRow.alignment = NSLayoutAttributeCenterY;
    pluginHeaderRow.spacing = 10;
    pluginHeaderRow.translatesAutoresizingMaskIntoConstraints = NO;
    NSTextField *pluginHeader = QTPLabel(@"Installed Plugins", [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.labelColor);
    NSTextField *pluginCount = QTPLabel([NSString stringWithFormat:@"%lu found", plugins.count], [NSFont systemFontOfSize:NSFont.smallSystemFontSize], NSColor.secondaryLabelColor);
    [pluginHeaderRow addArrangedSubview:pluginHeader];
    [pluginHeaderRow addArrangedSubview:pluginCount];
    [pluginColumn addArrangedSubview:pluginHeaderRow];

    NSScrollView *pluginScrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
    pluginScrollView.hasVerticalScroller = YES;
    pluginScrollView.borderType = NSNoBorder;
    pluginScrollView.drawsBackground = NO;
    pluginScrollView.translatesAutoresizingMaskIntoConstraints = NO;

    NSStackView *pluginList = [[NSStackView alloc] initWithFrame:NSZeroRect];
    pluginList.orientation = NSUserInterfaceLayoutOrientationVertical;
    pluginList.alignment = NSLayoutAttributeLeading;
    pluginList.spacing = 10;
    pluginList.edgeInsets = NSEdgeInsetsMake(0, 0, 0, 8);
    pluginList.translatesAutoresizingMaskIntoConstraints = NO;

    for (NSDictionary<NSString *, id> *plugin in plugins) {
        NSString *identifier = plugin[@"identifier"];
        BOOL enabled = ![disabledIdentifiers containsObject:identifier];

        NSView *card = [[NSView alloc] initWithFrame:NSZeroRect];
        card.wantsLayer = YES;
        card.layer.cornerRadius = 8;
        card.layer.borderWidth = 1;
        card.layer.borderColor = NSColor.separatorColor.CGColor;
        card.layer.backgroundColor = NSColor.controlBackgroundColor.CGColor;
        card.translatesAutoresizingMaskIntoConstraints = NO;

        NSStackView *cardStack = [[NSStackView alloc] initWithFrame:NSZeroRect];
        cardStack.orientation = NSUserInterfaceLayoutOrientationVertical;
        cardStack.alignment = NSLayoutAttributeLeading;
        cardStack.spacing = 6;
        cardStack.edgeInsets = NSEdgeInsetsMake(12, 12, 12, 12);
        cardStack.translatesAutoresizingMaskIntoConstraints = NO;
        [card addSubview:cardStack];

        NSStackView *nameRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
        nameRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        nameRow.alignment = NSLayoutAttributeCenterY;
        nameRow.spacing = 8;
        nameRow.translatesAutoresizingMaskIntoConstraints = NO;

        NSButton *checkbox = [NSButton checkboxWithTitle:plugin[@"name"] ?: @"Plugin" target:self action:@selector(togglePlugin:)];
        checkbox.identifier = identifier;
        checkbox.state = enabled ? NSControlStateValueOn : NSControlStateValueOff;
        checkbox.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:NSFontWeightSemibold];
        checkbox.translatesAutoresizingMaskIntoConstraints = NO;
        checkbox.toolTip = @"Changes apply the next time QuickTime Player Plus starts.";
        NSTextField *stateLabel = QTPLabel(enabled ? @"Enabled" : @"Disabled", [NSFont systemFontOfSize:NSFont.smallSystemFontSize], enabled ? NSColor.systemGreenColor : NSColor.secondaryLabelColor);
        [nameRow addArrangedSubview:checkbox];
        [nameRow addArrangedSubview:stateLabel];
        [cardStack addArrangedSubview:nameRow];

        NSArray<NSString *> *extensions = plugin[@"extensions"];
        NSString *extensionText = extensions.count > 0 ? [extensions componentsJoinedByString:@", "] : @"No declared extensions";
        NSString *description = [plugin[@"description"] length] > 0 ? plugin[@"description"] : @"No description provided.";
        NSTextField *descriptionLabel = QTPLabel(description, [NSFont systemFontOfSize:NSFont.smallSystemFontSize], NSColor.secondaryLabelColor);
        descriptionLabel.maximumNumberOfLines = 2;
        NSTextField *extensionLabel = QTPLabel([NSString stringWithFormat:@"Extensions: %@", extensionText], [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular], NSColor.tertiaryLabelColor);
        extensionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        extensionLabel.maximumNumberOfLines = 1;
        NSTextField *pathLabel = QTPLabel(plugin[@"path"], [NSFont systemFontOfSize:NSFont.smallSystemFontSize], NSColor.tertiaryLabelColor);
        pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        pathLabel.maximumNumberOfLines = 1;
        [cardStack addArrangedSubview:descriptionLabel];
        [cardStack addArrangedSubview:extensionLabel];
        [cardStack addArrangedSubview:pathLabel];

        [cardStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor].active = YES;
        [cardStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor].active = YES;
        [cardStack.topAnchor constraintEqualToAnchor:card.topAnchor].active = YES;
        [cardStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor].active = YES;
        [card.widthAnchor constraintEqualToConstant:500].active = YES;
        [pluginList addArrangedSubview:card];
    }

    if (plugins.count == 0) {
        NSTextField *empty = QTPLabel(@"No .qtplugin bundles were found.", [NSFont systemFontOfSize:NSFont.systemFontSize], NSColor.secondaryLabelColor);
        [pluginList addArrangedSubview:empty];
    }

    pluginScrollView.documentView = pluginList;
    [pluginColumn addArrangedSubview:pluginScrollView];

    NSStackView *pluginActions = [[NSStackView alloc] initWithFrame:NSZeroRect];
    pluginActions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    pluginActions.alignment = NSLayoutAttributeCenterY;
    pluginActions.spacing = 8;
    pluginActions.translatesAutoresizingMaskIntoConstraints = NO;
    [pluginActions addArrangedSubview:QTPActionButton(@"Add Plugin...", self, @selector(addPlugin:))];
    [pluginActions addArrangedSubview:QTPActionButton(@"Open Folder", self, @selector(openPluginFolder:))];
    [pluginColumn addArrangedSubview:pluginActions];

    NSStackView *settingsColumn = [[NSStackView alloc] initWithFrame:NSZeroRect];
    settingsColumn.orientation = NSUserInterfaceLayoutOrientationVertical;
    settingsColumn.alignment = NSLayoutAttributeLeading;
    settingsColumn.spacing = 14;
    settingsColumn.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *settingsHeader = QTPLabel(@"Renderer Settings", [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.labelColor);
    [settingsColumn addArrangedSubview:settingsHeader];

    NSString *ffmpegPath = [NSUserDefaults.standardUserDefaults stringForKey:QTPFFmpegPathKey];
    NSString *fluidSynthPath = [NSUserDefaults.standardUserDefaults stringForKey:QTPFluidSynthPathKey];
    NSString *soundFontPath = [NSUserDefaults.standardUserDefaults stringForKey:QTPMIDISoundFontPathKey];
    [settingsColumn addArrangedSubview:QTPPathRow(@"ffmpeg", ffmpegPath, @"Auto-detect: /opt/homebrew/bin/ffmpeg or /usr/local/bin/ffmpeg", QTPActionButton(@"Choose...", self, @selector(chooseFFmpeg:)))];
    [settingsColumn addArrangedSubview:QTPPathRow(@"FluidSynth", fluidSynthPath, @"Optional. Apple DLS is used when FluidSynth is unavailable.", QTPActionButton(@"Choose...", self, @selector(chooseFluidSynth:)))];
    [settingsColumn addArrangedSubview:QTPPathRow(@"MIDI SoundFont", soundFontPath, @"Auto SoundFont/DLS lookup", QTPActionButton(@"Choose...", self, @selector(chooseMIDISoundFont:)))];

    [settingsColumn addArrangedSubview:QTPSeparator()];

    NSTextField *maintenanceHeader = QTPLabel(@"Maintenance", [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.labelColor);
    NSTextField *maintenanceText = QTPLabel(@"Rendered MIDI, transcode, animated image, and image sequence outputs are temporary. Clear them if playback tests start using stale media.", [NSFont systemFontOfSize:NSFont.smallSystemFontSize], NSColor.secondaryLabelColor);
    [settingsColumn addArrangedSubview:maintenanceHeader];
    [settingsColumn addArrangedSubview:maintenanceText];
    [settingsColumn addArrangedSubview:QTPActionButton(@"Clear Render Caches", self, @selector(clearCaches:))];

    [settingsColumn addArrangedSubview:QTPSeparator()];

    NSTextField *restartLabel = QTPLabel(@"Plugin enable/disable changes apply after restarting QuickTime Player Plus.", [NSFont systemFontOfSize:NSFont.smallSystemFontSize], NSColor.secondaryLabelColor);
    [settingsColumn addArrangedSubview:restartLabel];

    [mainStack addArrangedSubview:pluginColumn];
    [mainStack addArrangedSubview:settingsColumn];
    [pluginColumn.widthAnchor constraintGreaterThanOrEqualToConstant:520].active = YES;
    [settingsColumn.widthAnchor constraintGreaterThanOrEqualToConstant:260].active = YES;
    [pluginScrollView.heightAnchor constraintGreaterThanOrEqualToConstant:360].active = YES;

    [NSLayoutConstraint activateConstraints:@[
        [rootStack.leadingAnchor constraintEqualToAnchor:contentView.leadingAnchor],
        [rootStack.trailingAnchor constraintEqualToAnchor:contentView.trailingAnchor],
        [rootStack.topAnchor constraintEqualToAnchor:contentView.topAnchor],
        [rootStack.bottomAnchor constraintEqualToAnchor:contentView.bottomAnchor],
        [mainStack.widthAnchor constraintEqualToAnchor:rootStack.widthAnchor constant:-48],
        [pluginList.widthAnchor constraintEqualToAnchor:pluginScrollView.contentView.widthAnchor],
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

- (void)chooseFluidSynth:(__unused id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Use";
    panel.message = @"Choose the fluidsynth executable used by the MIDI plugin.";

    if ([panel runModal] == NSModalResponseOK) {
        [NSUserDefaults.standardUserDefaults setObject:panel.URL.path forKey:QTPFluidSynthPathKey];
        [self showWindow];
    }
}

- (void)chooseMIDISoundFont:(__unused id)sender
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.prompt = @"Use";
    panel.message = @"Choose the SoundFont or DLS bank used by the MIDI plugin.";

    if ([panel runModal] == NSModalResponseOK) {
        [NSUserDefaults.standardUserDefaults setObject:panel.URL.path forKey:QTPMIDISoundFontPathKey];
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
