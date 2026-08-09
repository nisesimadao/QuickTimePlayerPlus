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
- (void)showPluginSettings:(id)sender;
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

static BOOL QTPUsesJapanese(void)
{
    NSArray<NSString *> *languages = [NSUserDefaults.standardUserDefaults objectForKey:@"AppleLanguages"];
    NSString *primaryLanguage = languages.firstObject ?: NSLocale.preferredLanguages.firstObject ?: @"";
    return [primaryLanguage hasPrefix:@"ja"];
}

static NSString *QTPLocalized(NSString *english, NSString *japanese)
{
    return QTPUsesJapanese() ? japanese : english;
}

static BOOL QTPPluginUsesMIDISettings(NSString *identifier)
{
    return [identifier containsString:@"midi"];
}

static BOOL QTPPluginUsesFFmpegSettings(NSString *identifier)
{
    return [identifier containsString:@"transcode"] ||
           [identifier containsString:@"animated-image"] ||
           [identifier containsString:@"game-audio"] ||
           [identifier containsString:@"image-sequence"];
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
    valueLabel.lineBreakMode = NSLineBreakByWordWrapping;
    valueLabel.maximumNumberOfLines = 3;
    valueLabel.selectable = YES;
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
    window.title = QTPLocalized(@"Plugin Manager", @"プラグイン管理");
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
    NSTextField *subtitleLabel = QTPLabel(QTPLocalized(@"Manage installed plugins, per-plugin settings, and temporary render caches.", @"インストール済みプラグイン、プラグイン別設定、一時レンダーキャッシュを管理します。"), [NSFont systemFontOfSize:NSFont.systemFontSize], NSColor.secondaryLabelColor);
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
    NSTextField *pluginHeader = QTPLabel(QTPLocalized(@"Installed Plugins", @"インストール済みプラグイン"), [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.labelColor);
    NSTextField *pluginCount = QTPLabel([NSString stringWithFormat:QTPLocalized(@"%lu found", @"%lu 個"), plugins.count], [NSFont systemFontOfSize:NSFont.smallSystemFontSize], NSColor.secondaryLabelColor);
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
        checkbox.toolTip = QTPLocalized(@"Changes apply the next time QuickTime Player Plus starts.", @"変更は次回の QuickTime Player Plus 起動時に反映されます。");
        NSTextField *stateLabel = QTPLabel(enabled ? QTPLocalized(@"Enabled", @"有効") : QTPLocalized(@"Disabled", @"無効"), [NSFont systemFontOfSize:NSFont.smallSystemFontSize], enabled ? NSColor.systemGreenColor : NSColor.secondaryLabelColor);
        NSButton *settingsButton = QTPActionButton(QTPLocalized(@"Settings...", @"設定..."), self, @selector(showPluginSettings:));
        settingsButton.identifier = identifier;
        settingsButton.enabled = QTPPluginUsesMIDISettings(identifier) || QTPPluginUsesFFmpegSettings(identifier);
        [nameRow addArrangedSubview:checkbox];
        [nameRow addArrangedSubview:stateLabel];
        [nameRow addArrangedSubview:settingsButton];
        [cardStack addArrangedSubview:nameRow];

        NSArray<NSString *> *extensions = plugin[@"extensions"];
        NSString *extensionText = extensions.count > 0 ? [extensions componentsJoinedByString:@", "] : QTPLocalized(@"No declared extensions", @"宣言された拡張子なし");
        NSString *description = [plugin[@"description"] length] > 0 ? plugin[@"description"] : QTPLocalized(@"No description provided.", @"説明がありません。");
        NSTextField *descriptionLabel = QTPLabel(description, [NSFont systemFontOfSize:NSFont.smallSystemFontSize], NSColor.secondaryLabelColor);
        descriptionLabel.maximumNumberOfLines = 2;
        NSTextField *extensionLabel = QTPLabel([NSString stringWithFormat:@"%@: %@", QTPLocalized(@"Extensions", @"拡張子"), extensionText], [NSFont monospacedSystemFontOfSize:11 weight:NSFontWeightRegular], NSColor.tertiaryLabelColor);
        extensionLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        extensionLabel.maximumNumberOfLines = 1;
        NSTextField *pathLabel = QTPLabel(plugin[@"path"], [NSFont systemFontOfSize:NSFont.smallSystemFontSize], NSColor.tertiaryLabelColor);
        pathLabel.lineBreakMode = NSLineBreakByWordWrapping;
        pathLabel.maximumNumberOfLines = 2;
        pathLabel.selectable = YES;
        [cardStack addArrangedSubview:descriptionLabel];
        [cardStack addArrangedSubview:extensionLabel];
        [cardStack addArrangedSubview:pathLabel];

        [cardStack.leadingAnchor constraintEqualToAnchor:card.leadingAnchor].active = YES;
        [cardStack.trailingAnchor constraintEqualToAnchor:card.trailingAnchor].active = YES;
        [cardStack.topAnchor constraintEqualToAnchor:card.topAnchor].active = YES;
        [cardStack.bottomAnchor constraintEqualToAnchor:card.bottomAnchor].active = YES;
        [card.widthAnchor constraintEqualToConstant:540].active = YES;
        [pluginList addArrangedSubview:card];
    }

    if (plugins.count == 0) {
        NSTextField *empty = QTPLabel(QTPLocalized(@"No .qtplugin bundles were found.", @".qtplugin bundle が見つかりません。"), [NSFont systemFontOfSize:NSFont.systemFontSize], NSColor.secondaryLabelColor);
        [pluginList addArrangedSubview:empty];
    }

    pluginScrollView.documentView = pluginList;
    [pluginColumn addArrangedSubview:pluginScrollView];

    NSStackView *pluginActions = [[NSStackView alloc] initWithFrame:NSZeroRect];
    pluginActions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    pluginActions.alignment = NSLayoutAttributeCenterY;
    pluginActions.spacing = 8;
    pluginActions.translatesAutoresizingMaskIntoConstraints = NO;
    [pluginActions addArrangedSubview:QTPActionButton(QTPLocalized(@"Add Plugin...", @"プラグインを追加..."), self, @selector(addPlugin:))];
    [pluginActions addArrangedSubview:QTPActionButton(QTPLocalized(@"Open Folder", @"フォルダを開く"), self, @selector(openPluginFolder:))];
    [pluginColumn addArrangedSubview:pluginActions];

    NSStackView *settingsColumn = [[NSStackView alloc] initWithFrame:NSZeroRect];
    settingsColumn.orientation = NSUserInterfaceLayoutOrientationVertical;
    settingsColumn.alignment = NSLayoutAttributeLeading;
    settingsColumn.spacing = 14;
    settingsColumn.translatesAutoresizingMaskIntoConstraints = NO;

    NSTextField *maintenanceHeader = QTPLabel(QTPLocalized(@"Maintenance", @"メンテナンス"), [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.labelColor);
    NSTextField *maintenanceText = QTPLabel(QTPLocalized(@"Rendered MIDI, transcode, animated image, and image sequence outputs are temporary. Clear them if playback tests start using stale media.", @"MIDI、変換メディア、アニメーション画像、連番画像のレンダー結果は一時ファイルです。古い結果が使われる場合は削除してください。"), [NSFont systemFontOfSize:NSFont.smallSystemFontSize], NSColor.secondaryLabelColor);
    [settingsColumn addArrangedSubview:maintenanceHeader];
    [settingsColumn addArrangedSubview:maintenanceText];
    [settingsColumn addArrangedSubview:QTPActionButton(QTPLocalized(@"Clear Render Caches", @"レンダーキャッシュを削除"), self, @selector(clearCaches:))];

    [settingsColumn addArrangedSubview:QTPSeparator()];

    NSTextField *restartLabel = QTPLabel(QTPLocalized(@"Plugin enable/disable changes apply after restarting QuickTime Player Plus. Renderer settings are available from each plugin card.", @"プラグインの有効/無効は QuickTime Player Plus の再起動後に反映されます。renderer 設定は各プラグインカードの「設定...」から変更します。"), [NSFont systemFontOfSize:NSFont.smallSystemFontSize], NSColor.secondaryLabelColor);
    [settingsColumn addArrangedSubview:restartLabel];

    [mainStack addArrangedSubview:pluginColumn];
    [mainStack addArrangedSubview:settingsColumn];
    [pluginColumn.widthAnchor constraintGreaterThanOrEqualToConstant:560].active = YES;
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

- (void)choosePathForDefaultsKey:(NSString *)defaultsKey
                          prompt:(NSString *)prompt
                         message:(NSString *)message
{
    NSOpenPanel *panel = [NSOpenPanel openPanel];
    panel.canChooseFiles = YES;
    panel.canChooseDirectories = NO;
    panel.allowsMultipleSelection = NO;
    panel.prompt = prompt;
    panel.message = message;

    if ([panel runModal] == NSModalResponseOK) {
        [NSUserDefaults.standardUserDefaults setObject:panel.URL.path forKey:defaultsKey];
        [self showWindow];
    }
}

- (void)showPluginSettings:(NSButton *)sender
{
    NSString *identifier = sender.identifier ?: @"";
    NSDictionary<NSString *, id> *targetPlugin = nil;
    for (NSDictionary<NSString *, id> *plugin in QTPInstalledPluginInfos()) {
        if ([plugin[@"identifier"] isEqualToString:identifier]) {
            targetPlugin = plugin;
            break;
        }
    }

    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = [NSString stringWithFormat:QTPLocalized(@"%@ Settings", @"%@ の設定"), targetPlugin[@"name"] ?: QTPLocalized(@"Plugin", @"プラグイン")];
    alert.informativeText = QTPLocalized(@"Paths are stored for the renderer used by this plugin. Existing QuickTime windows may need to be reopened.", @"このプラグインが使う renderer のパスを保存します。既に開いている QuickTime ウィンドウは開き直しが必要な場合があります。");
    [alert addButtonWithTitle:QTPLocalized(@"Done", @"完了")];

    NSStackView *settingsStack = [[NSStackView alloc] initWithFrame:NSMakeRect(0, 0, 520, 10)];
    settingsStack.orientation = NSUserInterfaceLayoutOrientationVertical;
    settingsStack.alignment = NSLayoutAttributeLeading;
    settingsStack.spacing = 12;
    settingsStack.translatesAutoresizingMaskIntoConstraints = NO;

    if (QTPPluginUsesMIDISettings(identifier)) {
        NSString *fluidSynthPath = [NSUserDefaults.standardUserDefaults stringForKey:QTPFluidSynthPathKey];
        NSString *soundFontPath = [NSUserDefaults.standardUserDefaults stringForKey:QTPMIDISoundFontPathKey];
        [settingsStack addArrangedSubview:QTPPathRow(@"FluidSynth",
                                                     fluidSynthPath,
                                                     QTPLocalized(@"Optional. Apple DLS is used when FluidSynth is unavailable.", @"任意です。見つからない場合は Apple DLS fallback を使います。"),
                                                     QTPActionButton(QTPLocalized(@"Choose...", @"選択..."), self, @selector(chooseFluidSynth:)))];
        [settingsStack addArrangedSubview:QTPPathRow(QTPLocalized(@"MIDI SoundFont", @"MIDI SoundFont"),
                                                     soundFontPath,
                                                     QTPLocalized(@"Auto SoundFont/DLS lookup", @"SoundFont/DLS を自動検索"),
                                                     QTPActionButton(QTPLocalized(@"Choose...", @"選択..."), self, @selector(chooseMIDISoundFont:)))];
    }

    if (QTPPluginUsesFFmpegSettings(identifier)) {
        NSString *ffmpegPath = [NSUserDefaults.standardUserDefaults stringForKey:QTPFFmpegPathKey];
        [settingsStack addArrangedSubview:QTPPathRow(@"ffmpeg",
                                                     ffmpegPath,
                                                     QTPLocalized(@"Auto-detect: /opt/homebrew/bin/ffmpeg or /usr/local/bin/ffmpeg", @"自動検出: /opt/homebrew/bin/ffmpeg または /usr/local/bin/ffmpeg"),
                                                     QTPActionButton(QTPLocalized(@"Choose...", @"選択..."), self, @selector(chooseFFmpeg:)))];
    }

    if (settingsStack.arrangedSubviews.count == 0) {
        [settingsStack addArrangedSubview:QTPLabel(QTPLocalized(@"This plugin has no editable settings.", @"このプラグインには編集できる設定がありません。"), [NSFont systemFontOfSize:NSFont.systemFontSize], NSColor.secondaryLabelColor)];
    }

    [settingsStack.widthAnchor constraintEqualToConstant:520].active = YES;
    alert.accessoryView = settingsStack;
    [alert runModal];
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
    panel.prompt = QTPLocalized(@"Add", @"追加");
    panel.message = QTPLocalized(@"Choose .qtplugin bundles to copy into the user plugin folder.", @"ユーザープラグインフォルダへコピーする .qtplugin bundle を選択してください。");

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
    [self choosePathForDefaultsKey:QTPFFmpegPathKey
                            prompt:QTPLocalized(@"Use", @"使用")
                           message:QTPLocalized(@"Choose the ffmpeg executable used by this plugin.", @"このプラグインで使う ffmpeg 実行ファイルを選択してください。")];
}

- (void)chooseFluidSynth:(__unused id)sender
{
    [self choosePathForDefaultsKey:QTPFluidSynthPathKey
                            prompt:QTPLocalized(@"Use", @"使用")
                           message:QTPLocalized(@"Choose the fluidsynth executable used by the MIDI plugin.", @"MIDI プラグインで使う fluidsynth 実行ファイルを選択してください。")];
}

- (void)chooseMIDISoundFont:(__unused id)sender
{
    [self choosePathForDefaultsKey:QTPMIDISoundFontPathKey
                            prompt:QTPLocalized(@"Use", @"使用")
                           message:QTPLocalized(@"Choose the SoundFont or DLS bank used by the MIDI plugin.", @"MIDI プラグインで使う SoundFont または DLS bank を選択してください。")];
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
