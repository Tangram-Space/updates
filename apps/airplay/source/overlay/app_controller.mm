/* Local macOS application shell for the tested UxPlay receiver. GPL-3.0-or-later. */
#import <Cocoa/Cocoa.h>
#import <SystemConfiguration/SystemConfiguration.h>
#include <dispatch/dispatch.h>
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include "app_controller.h"
#include "renderers/macos_airplay_window.h"
#include "renderers/audio_renderer.h"

static NSString *const AppID = @"local.chevy.airplay";
static NSString *const LoginID = @"local.chevy.airplay.login";
static NSString *const NameKey = @"AirPlay.ReceiverName";
static NSString *const VolumeKey = @"AirPlay.LocalVolume";
static NSString *const MutedKey = @"AirPlay.LocalMuted";
static NSString *runningName = nil;
static NSString *logFolder = nil;
static gint appActive = 0;
static gint quitRequested = 0;
static gint sourceActive = 0;
static gint sourceUpdatePending = 0;
static int instanceLock = -1;
/* Used only by the explicit, offline UI check. Never changes AppleLanguages. */
static NSBundle *uiCheckLocalization = nil;

/* Keep GStreamer's application delegate and route Quit through the receiver loop. */
@interface AirPlayApplication : NSApplication
@end

/* Only the artwork changes: NSSliderCell keeps its knob geometry and tracking. */
@interface AirPlayVolumeSliderCell : NSSliderCell
@end

@implementation AirPlayVolumeSliderCell
- (void)drawBarInside:(NSRect)rect flipped:(BOOL)flipped
{
    NSRect knob = [self knobRectFlipped:flipped];
    NSRect bounds = [[self controlView] bounds];
    CGFloat height = MIN(22.0, NSHeight(bounds));
    rect.origin.y = NSMidY(knob) - height / 2.0;
    rect.size.height = height;
    rect = NSIntersectionRect(rect, bounds);
    if (NSIsEmptyRect(rect)) return;

    NSBezierPath *track = [NSBezierPath bezierPathWithRoundedRect:rect
        xRadius:height / 2.0 yRadius:height / 2.0];
    BOOL highContrast = [[NSWorkspace sharedWorkspace] accessibilityDisplayShouldIncreaseContrast];
    [[[NSColor secondaryLabelColor] colorWithAlphaComponent:highContrast ? 0.45 : 0.30] setFill];
    [track fill];

    CGFloat split = MAX(NSMinX(rect), MIN(NSMaxX(rect), NSMidX(knob)));
    NSRect filled = rect;
    if ([[self controlView] userInterfaceLayoutDirection] == NSUserInterfaceLayoutDirectionRightToLeft) {
        filled.origin.x = split;
        filled.size.width = NSMaxX(rect) - split;
    } else {
        filled.size.width = split - NSMinX(rect);
    }
    [NSGraphicsContext saveGraphicsState];
    [track addClip];
    [[[NSColor whiteColor] colorWithAlphaComponent:[self isEnabled] ? 1.0 : 0.5] setFill];
    NSRectFill(filled);
    [NSGraphicsContext restoreGraphicsState];
    if (highContrast) {
        NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(rect,0.5,0.5)
            xRadius:(height - 1.0) / 2.0 yRadius:(height - 1.0) / 2.0];
        [outline setLineWidth:1.0];
        [[[NSColor labelColor] colorWithAlphaComponent:0.6] setStroke];
        [outline stroke];
    }
}

- (void)drawKnob:(NSRect)knobRect
{
    /* Keep AppKit's native circular thumb and its exact hit area/end points. */
    CGFloat diameter = MIN(22.0, MIN(NSWidth(knobRect), NSHeight(knobRect)));
    NSRect circle = NSMakeRect(NSMidX(knobRect) - diameter / 2.0,
        NSMidY(knobRect) - diameter / 2.0, diameter, diameter);
    NSBezierPath *knob = [NSBezierPath bezierPathWithOvalInRect:circle];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [[[NSShadow alloc] init] autorelease];
    [shadow setShadowColor:[[NSColor blackColor] colorWithAlphaComponent:0.20]];
    [shadow setShadowOffset:NSMakeSize(0,-0.5)];
    [shadow setShadowBlurRadius:1.5];
    [shadow set];
    [[[NSColor whiteColor] colorWithAlphaComponent:[self isEnabled] ? 1.0 : 0.7] setFill];
    [knob fill];
    [NSGraphicsContext restoreGraphicsState];
    NSBezierPath *edge = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(circle,0.25,0.25)];
    [edge setLineWidth:0.5];
    BOOL highContrast = [[NSWorkspace sharedWorkspace] accessibilityDisplayShouldIncreaseContrast];
    [[[NSColor blackColor] colorWithAlphaComponent:highContrast ? 0.6 : 0.16] setStroke];
    [edge stroke];
}
@end

/* NSBundle follows preferred macOS languages and the bundle's regional/base lproj files. */
static NSString *L(NSString *key)
{
    return [(uiCheckLocalization ?: [NSBundle mainBundle]) localizedStringForKey:key value:key table:@"Localizable"];
}

static double saved_local_volume(void)
{
    id saved = [[NSUserDefaults standardUserDefaults] objectForKey:VolumeKey];
    double factor = [saved isKindOfClass:[NSNumber class]] ? [saved doubleValue] : 1.0;
    return std::isfinite(factor) ? MAX(0.0, MIN(1.0, factor)) : 1.0;
}

static NSString *computer_name(void)
{
    NSString *name = (NSString *)SCDynamicStoreCopyComputerName(NULL, NULL);
    [name autorelease];
    return [name length] ? name : @"iMac";
}

static BOOL valid_name(NSString *name)
{
    /* The RAOP service adds a 12-digit device ID and '@' to this DNS-SD label. */
    return [name isKindOfClass:[NSString class]] && [name length] > 0 &&
        ![name hasPrefix:@"-"] &&
        [name lengthOfBytesUsingEncoding:NSUTF8StringEncoding] <= 50 &&
        [name rangeOfCharacterFromSet:[NSCharacterSet controlCharacterSet]].location == NSNotFound;
}

static NSString *saved_name(void)
{
    id name = [[NSUserDefaults standardUserDefaults] objectForKey:NameKey];
    if (valid_name(name)) return name;
    name = computer_name();
    return valid_name(name) ? name : @"iMac";
}

static void show_error(NSString *message, NSString *detail)
{
    NSAlert *alert = [[[NSAlert alloc] init] autorelease];
    [alert setAlertStyle:NSAlertStyleWarning];
    [alert setMessageText:message];
    [alert setInformativeText:detail ?: @""];
    [alert addButtonWithTitle:L(@"OK")];
    [alert runModal];
}

static BOOL ensure_directory(NSString *path, NSError **error)
{
    return [[NSFileManager defaultManager] createDirectoryAtPath:path
        withIntermediateDirectories:YES
        attributes:@{NSFilePosixPermissions: @0700} error:error];
}

static NSString *login_path(void)
{
    return [NSHomeDirectory() stringByAppendingPathComponent:
        @"Library/LaunchAgents/local.chevy.airplay.login.plist"];
}

static BOOL owned_login(NSDictionary *entry)
{
    if (![entry isKindOfClass:[NSDictionary class]] ||
        ![[entry objectForKey:@"Label"] isKindOfClass:[NSString class]] ||
        ![[entry objectForKey:@"Label"] isEqualToString:LoginID]) return NO;
    id args = [entry objectForKey:@"ProgramArguments"];
    return [args isKindOfClass:[NSArray class]] && [args count] == 4 &&
        [[args objectAtIndex:0] isEqual:@"/usr/bin/open"] &&
        [[args objectAtIndex:1] isEqual:@"-g"] &&
        [[args objectAtIndex:2] isEqual:@"-a"] &&
        [[args objectAtIndex:3] isKindOfClass:[NSString class]] &&
        [[args objectAtIndex:3] hasSuffix:@".app"];
}

static BOOL login_enabled(void)
{
    NSDictionary *entry = [NSDictionary dictionaryWithContentsOfFile:login_path()];
    id runAtLoad = [entry objectForKey:@"RunAtLoad"];
    return owned_login(entry) && [runAtLoad isKindOfClass:[NSNumber class]] && [runAtLoad boolValue];
}

static BOOL set_login_enabled(BOOL enabled, NSError **error)
{
    NSFileManager *fm = [NSFileManager defaultManager];
    NSString *path = login_path();
    struct stat info;
    BOOL exists = lstat([path fileSystemRepresentation], &info) == 0;
    if (exists && (!S_ISREG(info.st_mode) ||
        !owned_login([NSDictionary dictionaryWithContentsOfFile:path]))) {
        if (error) *error = [NSError errorWithDomain:AppID code:1 userInfo:
            @{NSLocalizedDescriptionKey: L(@"The existing login item belongs to another app and was kept.")}];
        return NO;
    }
    if (!enabled) return !exists || [fm removeItemAtPath:path error:error];
    if (!ensure_directory([path stringByDeletingLastPathComponent], error)) return NO;
    NSString *bundlePath = [[[NSBundle mainBundle] bundlePath] stringByResolvingSymlinksInPath];
    NSDictionary *entry = @{
        @"Label": LoginID,
        @"ProgramArguments": @[@"/usr/bin/open", @"-g", @"-a", bundlePath],
        @"RunAtLoad": @YES,
        @"LimitLoadToSessionType": @"Aqua"
    };
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:entry
        format:NSPropertyListXMLFormat_v1_0 options:0 error:error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    chmod([path fileSystemRepresentation], 0600);
    /* No launchctl: this selection takes effect at the next user login. */
    return YES;
}

@interface AirPlayController : NSObject <NSMenuDelegate, NSPopoverDelegate> {
    NSWindow *settingsWindow;
    NSTextField *nameField;
    NSTextField *savedLabel;
    NSStatusItem *statusItem; /* Retained: NSStatusBar does not own its lifetime. */
    NSMenuItem *statusMenuItem; /* Owned by statusMenu. */
    NSMenuItem *updateAvailableMenuItem; /* Owned by statusMenu. */
    NSButton *loginCheckbox;
    NSButton *updateButton;
    NSButton *automaticUpdatesCheckbox;
    NSTextField *updateStatusLabel;
    AirPlayUpdateState updateState;
    NSString *availableVersion;
    BOOL checkingUI;
    NSMenu *statusMenu; /* Retained independently for the explicit right-click action. */
    NSPopover *volumePopover;
    NSSlider *volumeSlider;
    NSTextField *volumePercent;
    NSButton *muteButton;
    double localVolume;
    BOOL localMuted;
    BOOL ready;
    BOOL quitting;
}
- (id)initForUICheck;
- (BOOL)validateLayouts;
- (void)install;
- (void)updatePreferencesState;
- (void)checkForUpdates:(id)sender;
- (void)toggleAutomaticUpdates:(id)sender;
- (void)receiveUpdateState:(AirPlayUpdateState)state version:(NSString *)version;
- (void)statusClicked:(id)sender;
- (void)makeVolumePopover;
- (void)updateVolumeControls;
- (void)applyLocalVolume;
- (void)volumeChanged:(id)sender;
- (void)toggleMute:(id)sender;
- (void)sourceActivityChanged;
- (void)popoverDidClose:(NSNotification *)notification;
- (void)makeSettingsWindow;
- (void)updateStatus;
- (void)receiverReady;
- (void)showSettings:(id)sender;
- (void)showReceiver:(id)sender;
- (void)saveName:(id)sender;
- (void)useComputerName:(id)sender;
- (void)toggleLogin:(id)sender;
- (void)showLogs:(id)sender;
- (void)quit:(id)sender;
- (void)menuNeedsUpdate:(NSMenu *)menu;
- (void)willTerminate:(NSNotification *)notification;
@end

static AirPlayController *controller = nil; /* Lives for the application's lifetime. */

static NSTextField *label(NSRect frame, NSString *text, CGFloat size)
{
    NSTextField *view = [[[NSTextField alloc] initWithFrame:frame] autorelease];
    [view setEditable:NO];
    [view setSelectable:NO];
    [view setBezeled:NO];
    [view setDrawsBackground:NO];
    [view setFont:[NSFont systemFontOfSize:size]];
    [view setStringValue:text];
    return view;
}

static NSButton *button(NSRect frame, NSString *title, SEL action, id target)
{
    NSButton *view = [[[NSButton alloc] initWithFrame:frame] autorelease];
    [view setTitle:title];
    [view setBezelStyle:NSBezelStyleRounded];
    [view setButtonType:NSButtonTypeMomentaryPushIn];
    [view setTarget:target];
    [view setAction:action];
    return view;
}

static NSMenuItem *menu_item(NSMenu *menu, NSString *title, SEL action,
                     NSString *key, id target)
{
    NSMenuItem *item = [[[NSMenuItem alloc] initWithTitle:title action:action
        keyEquivalent:key] autorelease];
    [item setTarget:target];
    [menu addItem:item];
    return item;
}

/* Validate actual AppKit layout results, not a duplicate of the layout equations. */
static BOOL validate_layout(NSView *root, NSArray *identifiers, NSString *section)
{
    [root layoutSubtreeIfNeeded];
    NSMutableDictionary *controls = [NSMutableDictionary dictionary];
    for (NSView *view in [root subviews])
        if ([view identifier]) [controls setObject:view forKey:[view identifier]];
    NSRect bounds = NSInsetRect([root bounds], -0.5, -0.5);
    NSMutableArray *checked = [NSMutableArray array];
    for (NSString *identifier in identifiers) {
        NSView *view = [controls objectForKey:identifier];
        NSRect frame = view ? [view convertRect:[view bounds] toView:root] : NSZeroRect;
        if (!view || [view isHidden] || [view hasAmbiguousLayout] ||
            !std::isfinite(frame.origin.x) || !std::isfinite(frame.origin.y) ||
            !std::isfinite(frame.size.width) || !std::isfinite(frame.size.height) ||
            NSIsEmptyRect(frame) || !NSContainsRect(bounds, frame)) {
            fprintf(stderr, "AIRPLAY_UI_CHECK: %s/%s has a missing, ambiguous or out-of-bounds control %s\n",
                [section UTF8String], [identifier UTF8String], [NSStringFromRect(frame) UTF8String]);
            return NO;
        }
        /* Native bezels include invisible padding outside their alignment rect. */
        NSRect aligned = [view alignmentRectForFrame:[view frame]];
        for (NSValue *previous in checked) {
            if (NSIntersectsRect(aligned, [previous rectValue])) {
                fprintf(stderr, "AIRPLAY_UI_CHECK: %s/%s overlaps another control\n",
                    [section UTF8String], [identifier UTF8String]);
                return NO;
            }
        }
        [checked addObject:[NSValue valueWithRect:aligned]];
    }
    return YES;
}

@implementation AirPlayController
- (id)initForUICheck
{
    self = [super init];
    if (self) {
        checkingUI = YES;
        localVolume = 0.5;
        updateState = AIRPLAY_UPDATE_NOT_CONFIGURED;
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [volumePopover setDelegate:nil];
    [volumePopover release];
    [settingsWindow release];
    [availableVersion release];
    [statusMenu setDelegate:nil];
    [statusMenu release];
    if (statusItem) [[NSStatusBar systemStatusBar] removeStatusItem:statusItem];
    [statusItem release];
    [super dealloc];
}

- (BOOL)validateLayouts
{
    [self makeSettingsWindow];
    [self makeVolumePopover];
    if ([settingsWindow isVisible] || [volumePopover isShown]) return NO;
    return validate_layout([settingsWindow contentView], @[
        @"name-label",@"name-field",@"save",@"name-message",@"restore",
        @"login",@"logs",@"version",@"update-status",@"check-updates",@"automatic-updates"], @"preferences") &&
        validate_layout([[volumePopover contentViewController] view], @[
            @"volume-title",@"volume-percent",@"volume-slider",@"volume-mute"], @"volume");
}

- (void)install
{
    updateState = AIRPLAY_UPDATE_NOT_CONFIGURED;
    localVolume = saved_local_volume();
    localMuted = [[NSUserDefaults standardUserDefaults] boolForKey:MutedKey];
    audio_renderer_set_local_volume(localMuted ? 0.0 : localVolume);
    statusItem = [[[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength] retain];
    NSImage *symbol = [NSImage imageWithSystemSymbolName:@"airplayvideo" accessibilityDescription:@"AirPlay"];
    if (symbol) {
        [symbol setTemplate:YES];
        [[statusItem button] setImage:symbol];
    } else {
        [[statusItem button] setTitle:@"AirPlay"];
        g_printerr("AIRPLAY_APP system symbol unavailable; using status title\n");
    }
    [[statusItem button] setToolTip:@"AirPlay"];
    statusMenu = [[NSMenu alloc] initWithTitle:@"AirPlay"];
    [statusMenu setAutoenablesItems:NO];
    [statusMenu setDelegate:self];
    statusMenuItem = menu_item(statusMenu, L(@"Preparing receiver…"), NULL, @"", nil);
    [statusMenuItem setEnabled:NO];
    [statusMenu addItem:[NSMenuItem separatorItem]];
    menu_item(statusMenu, L(@"Show Window"), @selector(showReceiver:), @"", self);
    menu_item(statusMenu, L(@"Preferences…"), @selector(showSettings:), @"", self);
    updateAvailableMenuItem = menu_item(statusMenu, L(@"Update available…"),
        @selector(checkForUpdates:), @"", self);
    [updateAvailableMenuItem setHidden:YES];
    [statusMenu addItem:[NSMenuItem separatorItem]];
    menu_item(statusMenu, L(@"Quit AirPlay"), @selector(quit:), @"", self);
    [[statusItem button] setTarget:self];
    [[statusItem button] setAction:@selector(statusClicked:)];
    [[statusItem button] sendActionOn:NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp];
    [self sourceActivityChanged];

    /* Preserve editing/window keyboard shortcuts while a window is active. */
    NSMenu *main = [[[NSMenu alloc] initWithTitle:@"AirPlay"] autorelease];
    NSMenuItem *applicationItem = [[[NSMenuItem alloc] initWithTitle:@"AirPlay"
        action:NULL keyEquivalent:@""] autorelease];
    NSMenu *applicationMenu = [[[NSMenu alloc] initWithTitle:@"AirPlay"] autorelease];
    [applicationItem setSubmenu:applicationMenu];
    [main addItem:applicationItem];
    menu_item(applicationMenu, L(@"About AirPlay"), @selector(orderFrontStandardAboutPanel:), @"", NSApp);
    [applicationMenu addItem:[NSMenuItem separatorItem]];
    menu_item(applicationMenu, L(@"Preferences…"), @selector(showSettings:), @",", self);
    [applicationMenu addItem:[NSMenuItem separatorItem]];
    menu_item(applicationMenu, L(@"Hide AirPlay"), @selector(hide:), @"h", NSApp);
    menu_item(applicationMenu, L(@"Show All"), @selector(unhideAllApplications:), @"", NSApp);
    [applicationMenu addItem:[NSMenuItem separatorItem]];
    menu_item(applicationMenu, L(@"Quit AirPlay"), @selector(quit:), @"q", self);

    NSMenuItem *editItem = [[[NSMenuItem alloc] initWithTitle:L(@"Edit") action:NULL keyEquivalent:@""] autorelease];
    NSMenu *edit = [[[NSMenu alloc] initWithTitle:L(@"Edit")] autorelease];
    menu_item(edit, L(@"Undo"), @selector(undo:), @"z", nil);
    [edit addItem:[NSMenuItem separatorItem]];
    menu_item(edit, L(@"Cut"), @selector(cut:), @"x", nil);
    menu_item(edit, L(@"Copy"), @selector(copy:), @"c", nil);
    menu_item(edit, L(@"Paste"), @selector(paste:), @"v", nil);
    menu_item(edit, L(@"Select All"), @selector(selectAll:), @"a", nil);
    [editItem setSubmenu:edit];
    [main addItem:editItem];

    NSMenuItem *windowItem = [[[NSMenuItem alloc] initWithTitle:L(@"Window") action:NULL keyEquivalent:@""] autorelease];
    NSMenu *windows = [[[NSMenu alloc] initWithTitle:L(@"Window")] autorelease];
    menu_item(windows, L(@"Show Window"), @selector(showReceiver:), @"1", self);
    [windows addItem:[NSMenuItem separatorItem]];
    menu_item(windows, L(@"Minimize"), @selector(performMiniaturize:), @"m", nil);
    menu_item(windows, L(@"Zoom"), @selector(performZoom:), @"", nil);
    menu_item(windows, L(@"Close Window"), @selector(performClose:), @"w", nil);
    [windowItem setSubmenu:windows];
    [main addItem:windowItem];
    [NSApp setMainMenu:main];
    [NSApp setWindowsMenu:windows];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(willTerminate:)
        name:NSApplicationWillTerminateNotification object:NSApp];
    [self updateStatus];
    airplay_app_updater_initialize();
}

- (void)makeSettingsWindow
{
    if (settingsWindow) return;
    @try {
        settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0,0,440,346)
            styleMask:NSWindowStyleMaskTitled|NSWindowStyleMaskClosable
            backing:NSBackingStoreBuffered defer:NO];
        [settingsWindow setReleasedWhenClosed:NO];
        [settingsWindow setRestorable:NO];
        [settingsWindow setTitle:L(@"AirPlay Preferences")];
        if (!checkingUI) {
            BOOL restored = [settingsWindow setFrameUsingName:@"AirPlay.Settings.Window"];
            [settingsWindow setFrameAutosaveName:@"AirPlay.Settings.Window"];
            [settingsWindow setContentSize:NSMakeSize(440,346)];
            if (!restored) [settingsWindow center];
        }
        NSView *content = [settingsWindow contentView];
        NSTextField *nameLabel = label(NSZeroRect, L(@"Receiver name"), 13);
        [nameLabel setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]];
        nameField = [[[NSTextField alloc] initWithFrame:NSZeroRect] autorelease];
        [[nameField cell] setBezelStyle:NSTextFieldRoundedBezel];
        [nameField setFont:[NSFont systemFontOfSize:13]];
        [nameField setContentHuggingPriority:NSLayoutPriorityDefaultLow-1
            forOrientation:NSLayoutConstraintOrientationHorizontal];
        [nameField setStringValue:checkingUI ? @"AirPlay" : saved_name()];
        [nameField setTarget:self];
        [nameField setAction:@selector(saveName:)];
        [nameField setAccessibilityLabel:L(@"Receiver name")];
        NSButton *save = button(NSZeroRect, L(@"Save"), @selector(saveName:), self);
        [save setKeyEquivalent:@"\r"];
        savedLabel = label(NSZeroRect, L(@"Changes apply the next time you open AirPlay."), 12);
        [savedLabel setTextColor:[NSColor secondaryLabelColor]];
        [[savedLabel cell] setWraps:YES];
        [[savedLabel cell] setScrollable:NO];
        NSButton *restore = button(NSZeroRect, L(@"Use computer name"), @selector(useComputerName:), self);
        /* NSButton exposes bordered; bezeled belongs to NSTextField/NSCell. */
        [restore setBordered:NO];
        [restore setAttributedTitle:[[[NSAttributedString alloc] initWithString:L(@"Use computer name")
            attributes:@{NSFontAttributeName:[NSFont systemFontOfSize:12],
                         NSForegroundColorAttributeName:[NSColor linkColor]}] autorelease]];
        NSBox *firstDivider = [[[NSBox alloc] initWithFrame:NSZeroRect] autorelease];
        [firstDivider setBoxType:NSBoxSeparator];
        loginCheckbox = [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease];
        [loginCheckbox setButtonType:NSButtonTypeSwitch];
        [loginCheckbox setTitle:L(@"Open at Login")];
        [loginCheckbox setFont:[NSFont systemFontOfSize:13]];
        [loginCheckbox setTarget:self];
        [loginCheckbox setAction:@selector(toggleLogin:)];
        [loginCheckbox setState:(!checkingUI && login_enabled()) ? NSControlStateValueOn : NSControlStateValueOff];
        NSButton *logs = button(NSZeroRect, L(@"Show Logs"), @selector(showLogs:), self);
        NSBox *secondDivider = [[[NSBox alloc] initWithFrame:NSZeroRect] autorelease];
        [secondDivider setBoxType:NSBoxSeparator];
        NSString *version = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
        if (![version isKindOfClass:[NSString class]] || ![version length]) version = @"—";
        NSTextField *versionLabel = label(NSZeroRect, [NSString stringWithFormat:L(@"Version %@"),version], 13);
        [versionLabel setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]];
        updateStatusLabel = label(NSZeroRect, @"", 12);
        [updateStatusLabel setTextColor:[NSColor secondaryLabelColor]];
        [[updateStatusLabel cell] setWraps:YES];
        [[updateStatusLabel cell] setScrollable:NO];
        updateButton = button(NSZeroRect, L(@"Check for Updates…"), @selector(checkForUpdates:), self);
        automaticUpdatesCheckbox = [[[NSButton alloc] initWithFrame:NSZeroRect] autorelease];
        [automaticUpdatesCheckbox setButtonType:NSButtonTypeSwitch];
        [automaticUpdatesCheckbox setTitle:L(@"Check for updates automatically")];
        [automaticUpdatesCheckbox setFont:[NSFont systemFontOfSize:13]];
        [automaticUpdatesCheckbox setTarget:self];
        [automaticUpdatesCheckbox setAction:@selector(toggleAutomaticUpdates:)];
        [automaticUpdatesCheckbox setState:NSControlStateValueOff];
    
        NSArray *views = @[nameLabel,nameField,save,savedLabel,restore,firstDivider,
            loginCheckbox,logs,secondDivider,versionLabel,updateStatusLabel,updateButton,automaticUpdatesCheckbox];
        NSArray *identifiers = @[@"name-label",@"name-field",@"save",@"name-message",@"restore",@"divider-1",
            @"login",@"logs",@"divider-2",@"version",@"update-status",@"check-updates",@"automatic-updates"];
        for (NSUInteger i=0; i<[views count]; ++i) {
            NSView *view = [views objectAtIndex:i];
            [view setIdentifier:[identifiers objectAtIndex:i]];
            [view setTranslatesAutoresizingMaskIntoConstraints:NO];
            [content addSubview:view];
        }
        [NSLayoutConstraint activateConstraints:@[
            [[nameLabel leadingAnchor] constraintEqualToAnchor:[content leadingAnchor] constant:24],
            [[nameLabel trailingAnchor] constraintEqualToAnchor:[content trailingAnchor] constant:-24],
            [[nameLabel topAnchor] constraintEqualToAnchor:[content topAnchor] constant:20],
            [[nameLabel heightAnchor] constraintEqualToConstant:18],
            [[nameField leadingAnchor] constraintEqualToAnchor:[nameLabel leadingAnchor]],
            [[nameField trailingAnchor] constraintEqualToAnchor:[save leadingAnchor] constant:-12],
            [[nameField topAnchor] constraintEqualToAnchor:[nameLabel bottomAnchor] constant:8],
            [[nameField heightAnchor] constraintEqualToConstant:28],
            [[save trailingAnchor] constraintEqualToAnchor:[nameLabel trailingAnchor]],
            [[save centerYAnchor] constraintEqualToAnchor:[nameField centerYAnchor]],
            [[save widthAnchor] constraintGreaterThanOrEqualToConstant:90],
            [[save heightAnchor] constraintEqualToConstant:32],
            [[savedLabel leadingAnchor] constraintEqualToAnchor:[nameLabel leadingAnchor]],
            [[savedLabel trailingAnchor] constraintEqualToAnchor:[nameLabel trailingAnchor]],
            [[savedLabel topAnchor] constraintEqualToAnchor:[nameField bottomAnchor] constant:8],
            [[savedLabel heightAnchor] constraintEqualToConstant:32],
            [[restore leadingAnchor] constraintEqualToAnchor:[nameLabel leadingAnchor]],
            [[restore topAnchor] constraintEqualToAnchor:[savedLabel bottomAnchor] constant:4],
            [[restore heightAnchor] constraintEqualToConstant:24],
            [[firstDivider leadingAnchor] constraintEqualToAnchor:[nameLabel leadingAnchor]],
            [[firstDivider trailingAnchor] constraintEqualToAnchor:[nameLabel trailingAnchor]],
            [[firstDivider topAnchor] constraintEqualToAnchor:[restore bottomAnchor] constant:12],
            [[firstDivider heightAnchor] constraintEqualToConstant:1],
            [[loginCheckbox leadingAnchor] constraintEqualToAnchor:[nameLabel leadingAnchor]],
            [[loginCheckbox topAnchor] constraintEqualToAnchor:[firstDivider bottomAnchor] constant:17],
            [[loginCheckbox heightAnchor] constraintEqualToConstant:22],
            [[loginCheckbox trailingAnchor] constraintLessThanOrEqualToAnchor:[logs leadingAnchor] constant:-16],
            [[logs trailingAnchor] constraintEqualToAnchor:[nameLabel trailingAnchor]],
            [[logs centerYAnchor] constraintEqualToAnchor:[loginCheckbox centerYAnchor]],
            [[logs heightAnchor] constraintEqualToConstant:28],
            [[secondDivider leadingAnchor] constraintEqualToAnchor:[nameLabel leadingAnchor]],
            [[secondDivider trailingAnchor] constraintEqualToAnchor:[nameLabel trailingAnchor]],
            [[secondDivider topAnchor] constraintEqualToAnchor:[loginCheckbox bottomAnchor] constant:20],
            [[secondDivider heightAnchor] constraintEqualToConstant:1],
            [[versionLabel leadingAnchor] constraintEqualToAnchor:[nameLabel leadingAnchor]],
            [[versionLabel trailingAnchor] constraintLessThanOrEqualToAnchor:[updateButton leadingAnchor] constant:-16],
            [[versionLabel topAnchor] constraintEqualToAnchor:[secondDivider bottomAnchor] constant:16],
            [[versionLabel heightAnchor] constraintEqualToConstant:18],
            [[updateStatusLabel leadingAnchor] constraintEqualToAnchor:[nameLabel leadingAnchor]],
            [[updateStatusLabel trailingAnchor] constraintEqualToAnchor:[nameLabel trailingAnchor]],
            [[updateStatusLabel topAnchor] constraintEqualToAnchor:[automaticUpdatesCheckbox bottomAnchor] constant:6],
            [[updateStatusLabel heightAnchor] constraintEqualToConstant:32],
            [[updateButton trailingAnchor] constraintEqualToAnchor:[nameLabel trailingAnchor]],
            [[updateButton centerYAnchor] constraintEqualToAnchor:[versionLabel centerYAnchor]],
            [[updateButton heightAnchor] constraintEqualToConstant:28],
            [[updateButton widthAnchor] constraintGreaterThanOrEqualToConstant:180],
            [[automaticUpdatesCheckbox leadingAnchor] constraintEqualToAnchor:[nameLabel leadingAnchor]],
            [[automaticUpdatesCheckbox trailingAnchor] constraintEqualToAnchor:[nameLabel trailingAnchor]],
            [[automaticUpdatesCheckbox topAnchor] constraintEqualToAnchor:[updateButton bottomAnchor] constant:8],
            [[automaticUpdatesCheckbox heightAnchor] constraintEqualToConstant:22]
        ]];
        [self updatePreferencesState];
    } @catch (NSException *exception) {
        [settingsWindow release];
        settingsWindow = nil;
        nameField = nil;
        savedLabel = nil;
        loginCheckbox = nil;
        updateButton = nil;
        automaticUpdatesCheckbox = nil;
        updateStatusLabel = nil;
        @throw exception;
    }
}

- (void)makeVolumePopover
{
    if (volumePopover) return;
    @try {
        volumePopover = [[NSPopover alloc] init];
        [volumePopover setBehavior:NSPopoverBehaviorTransient];
        [volumePopover setDelegate:self];
        NSViewController *viewController = [[[NSViewController alloc] init] autorelease];
        NSView *view = [[[NSView alloc] initWithFrame:NSMakeRect(0,0,280,80)] autorelease];
        [viewController setView:view];
        [volumePopover setContentViewController:viewController];
        [volumePopover setContentSize:NSMakeSize(280,80)];
        NSTextField *title = label(NSZeroRect, L(@"Volume"), 13);
        [title setFont:[NSFont systemFontOfSize:13 weight:NSFontWeightSemibold]];
        volumePercent = label(NSZeroRect, @"", 13);
        [volumePercent setAlignment:NSTextAlignmentRight];
        [volumePercent setFont:[NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular]];
        volumeSlider = [[[NSSlider alloc] initWithFrame:NSZeroRect] autorelease];
        [volumeSlider setCell:[[[AirPlayVolumeSliderCell alloc] init] autorelease]];
        [volumeSlider setControlSize:NSControlSizeRegular];
        [volumeSlider setMinValue:0.0];
        [volumeSlider setMaxValue:100.0];
        [volumeSlider setContinuous:YES];
        [volumeSlider setTarget:self];
        [volumeSlider setAction:@selector(volumeChanged:)];
        [volumeSlider setAccessibilityLabel:L(@"AirPlay volume")];
        muteButton = button(NSZeroRect, @"", @selector(toggleMute:), self);
        [muteButton setButtonType:NSButtonTypePushOnPushOff];
        [muteButton setBordered:NO];
        [muteButton setImagePosition:NSImageOnly];
        [muteButton setImageScaling:NSImageScaleProportionallyDown];
        NSImageSymbolConfiguration *speakerConfiguration =
            [NSImageSymbolConfiguration configurationWithPointSize:14 weight:NSFontWeightRegular];
        NSImage *speaker = [[NSImage imageWithSystemSymbolName:@"speaker.wave.2.fill"
            accessibilityDescription:L(@"Mute")] imageWithSymbolConfiguration:speakerConfiguration];
        NSImage *mutedSpeaker = [[NSImage imageWithSystemSymbolName:@"speaker.slash.fill"
            accessibilityDescription:L(@"Unmute")] imageWithSymbolConfiguration:speakerConfiguration];
        [speaker setTemplate:YES];
        [mutedSpeaker setTemplate:YES];
        [muteButton setImage:speaker];
        [muteButton setAlternateImage:mutedSpeaker];
        [title setIdentifier:@"volume-title"];
        [volumePercent setIdentifier:@"volume-percent"];
        [volumeSlider setIdentifier:@"volume-slider"];
        [muteButton setIdentifier:@"volume-mute"];
        for (NSView *control in @[title,volumePercent,volumeSlider,muteButton]) {
            [control setTranslatesAutoresizingMaskIntoConstraints:NO];
            [view addSubview:control];
        }
        [NSLayoutConstraint activateConstraints:@[
            [[title leadingAnchor] constraintEqualToAnchor:[view leadingAnchor] constant:16],
            [[title topAnchor] constraintEqualToAnchor:[view topAnchor] constant:14],
            [[title heightAnchor] constraintEqualToConstant:18],
            [[title trailingAnchor] constraintLessThanOrEqualToAnchor:[volumePercent leadingAnchor] constant:-12],
            [[volumePercent trailingAnchor] constraintEqualToAnchor:[muteButton leadingAnchor] constant:-8],
            [[volumePercent firstBaselineAnchor] constraintEqualToAnchor:[title firstBaselineAnchor]],
            [[volumePercent widthAnchor] constraintGreaterThanOrEqualToConstant:56],
            [[volumeSlider leadingAnchor] constraintEqualToAnchor:[title leadingAnchor]],
            [[volumeSlider trailingAnchor] constraintEqualToAnchor:[view trailingAnchor] constant:-16],
            [[volumeSlider topAnchor] constraintEqualToAnchor:[title bottomAnchor] constant:10],
            [[volumeSlider heightAnchor] constraintEqualToConstant:22],
            [[muteButton trailingAnchor] constraintEqualToAnchor:[view trailingAnchor] constant:-16],
            [[muteButton centerYAnchor] constraintEqualToAnchor:[title centerYAnchor]],
            [[muteButton heightAnchor] constraintEqualToConstant:22],
            [[muteButton widthAnchor] constraintEqualToConstant:24]
        ]];
        [self updateVolumeControls];
    } @catch (NSException *exception) {
        [volumePopover setDelegate:nil];
        [volumePopover release];
        volumePopover = nil;
        volumeSlider = nil;
        volumePercent = nil;
        muteButton = nil;
        @throw exception;
    }
}

- (void)statusClicked:(id)sender
{
    (void)sender;
    NSEvent *event = [NSApp currentEvent];
    if ([event type] == NSEventTypeRightMouseUp ||
        ([event modifierFlags] & NSEventModifierFlagControl)) {
        if ([volumePopover isShown]) [volumePopover performClose:nil];
        [NSMenu popUpContextMenu:statusMenu withEvent:event forView:[statusItem button]];
        return;
    }
    if (!g_atomic_int_get(&sourceActive)) return;
    if ([volumePopover isShown]) { [volumePopover performClose:nil]; return; }
    [self makeVolumePopover];
    [self updateVolumeControls];
    [volumePopover showRelativeToRect:[[statusItem button] bounds]
        ofView:[statusItem button] preferredEdge:NSMinYEdge];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)updateVolumeControls
{
    double shown = localMuted ? 0.0 : localVolume;
    [volumeSlider setDoubleValue:shown * 100.0];
    [volumeSlider setNeedsDisplay:YES];
    [volumePercent setStringValue:[NSString stringWithFormat:L(@"%ld%%"), std::lround(shown * 100.0)]];
    NSString *muteAction = localMuted ? L(@"Unmute") : L(@"Mute");
    [muteButton setAccessibilityLabel:muteAction];
    [muteButton setToolTip:muteAction];
    [muteButton setState:localMuted ? NSControlStateValueOn : NSControlStateValueOff];
}

- (void)applyLocalVolume
{
    audio_renderer_set_local_volume(localMuted ? 0.0 : localVolume);
    [[NSUserDefaults standardUserDefaults] setDouble:localVolume forKey:VolumeKey];
    [[NSUserDefaults standardUserDefaults] setBool:localMuted forKey:MutedKey];
    [self updateVolumeControls];
}

- (void)volumeChanged:(id)sender
{
    (void)sender;
    double value = MAX(0.0, MIN(1.0, [volumeSlider doubleValue] / 100.0));
    if (!localMuted || value > 0.0) localVolume = value;
    if (value > 0.0) localMuted = NO;
    [self applyLocalVolume];
}

- (void)toggleMute:(id)sender
{
    (void)sender;
    localMuted = !localMuted; /* Keep the previous slider value for Unmute. */
    [self applyLocalVolume];
}

- (void)sourceActivityChanged
{
    BOOL active = g_atomic_int_get(&sourceActive) != 0;
    [[statusItem button] setToolTip:active ?
        L(@"AirPlay — click for volume; right-click for menu") : L(@"AirPlay — right-click for menu")];
    if (!active && [volumePopover isShown]) [volumePopover performClose:nil];
}

- (void)popoverDidClose:(NSNotification *)notification
{
    (void)notification;
    [[NSUserDefaults standardUserDefaults] synchronize];
}

- (void)updateStatus
{
    [statusMenuItem setTitle:quitting ? L(@"Closing AirPlay…") :
        ready ? [NSString stringWithFormat:L(@"Available as: %@"), runningName] : L(@"Preparing receiver…")];
}
- (void)receiverReady { ready=YES; [self updateStatus]; }
- (void)showSettings:(id)sender
{
    (void)sender;
    [self makeSettingsWindow];
    [loginCheckbox setState:login_enabled() ? NSControlStateValueOn : NSControlStateValueOff];
    [self updatePreferencesState];
    if ([settingsWindow isMiniaturized]) [settingsWindow deminiaturize:nil];
    [settingsWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
    [settingsWindow makeFirstResponder:nil];
}
- (void)showReceiver:(id)sender
{
    (void)sender;
    if (ux_macos_airplay_window_show()) [NSApp activateIgnoringOtherApps:YES];
}
- (void)menuNeedsUpdate:(NSMenu *)menu
{
    (void)menu;
    [self updateStatus];
}
- (void)useComputerName:(id)sender
{
    (void)sender;
    [nameField setStringValue:computer_name()];
    [savedLabel setStringValue:L(@"Changes apply the next time you open AirPlay.")];
}
- (void)saveName:(id)sender
{
    (void)sender;
    NSString *name = [[nameField stringValue] stringByTrimmingCharactersInSet:
        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!valid_name(name)) {
        show_error(L(@"Check the name"), L(@"Use a short name on one line, without a leading hyphen."));
        return;
    }
    [[NSUserDefaults standardUserDefaults] setObject:name forKey:NameKey];
    if (![[NSUserDefaults standardUserDefaults] synchronize]) {
        show_error(L(@"Couldn’t save the name"), L(@"Try saving your preferences again."));
        return;
    }
    [nameField setStringValue:name];
    [savedLabel setStringValue:[name isEqualToString:runningName] ? L(@"Name saved.") :
        L(@"Saved. Reopen AirPlay to use the new name.")];
}
- (void)toggleLogin:(id)sender
{
    (void)sender;
    NSError *error=nil;
    BOOL requested=!login_enabled();
    if (!set_login_enabled(requested, &error))
        show_error(L(@"Couldn’t change login settings"), [error localizedDescription]);
    [loginCheckbox setState:login_enabled() ? NSControlStateValueOn : NSControlStateValueOff];
}
- (void)updatePreferencesState
{
    /* The offline UI check must not read preferences or create the updater. */
    BOOL automaticEnabled = !checkingUI && airplay_app_automatic_updates_enabled();
    BOOL canCheck = !checkingUI && airplay_app_updater_can_check();
    NSString *message = L(@"Updates are not configured yet.");
    switch (updateState) {
        case AIRPLAY_UPDATE_IDLE:
            message = automaticEnabled ? L(@"AirPlay checks for updates automatically.") :
                L(@"Updates are checked only when you ask.");
            break;
        case AIRPLAY_UPDATE_CHECKING: message = L(@"Checking for updates…"); break;
        case AIRPLAY_UPDATE_AVAILABLE:
            message = [availableVersion length] ?
                [NSString stringWithFormat:L(@"Version %@ is available."),availableVersion] :
                L(@"An update is available.");
            break;
        case AIRPLAY_UPDATE_UP_TO_DATE: message = L(@"AirPlay is up to date."); break;
        case AIRPLAY_UPDATE_ERROR: message = L(@"Couldn’t check for updates. Try again."); break;
        case AIRPLAY_UPDATE_UNSUPPORTED: message = L(@"The available update is not compatible with this Mac."); break;
        case AIRPLAY_UPDATE_NOT_CONFIGURED: break;
    }
    [updateStatusLabel setStringValue:message];
    [updateButton setEnabled:canCheck];
    [automaticUpdatesCheckbox setState:automaticEnabled ? NSControlStateValueOn : NSControlStateValueOff];
    [automaticUpdatesCheckbox setEnabled:!checkingUI && airplay_app_updater_configured()];
    [updateAvailableMenuItem setHidden:updateState != AIRPLAY_UPDATE_AVAILABLE];
    [updateAvailableMenuItem setEnabled:canCheck];
}

- (void)receiveUpdateState:(AirPlayUpdateState)state version:(NSString *)version
{
    updateState = state;
    [availableVersion release];
    availableVersion = [version copy];
    [self updatePreferencesState];
}

- (void)checkForUpdates:(id)sender
{
    (void)sender;
    if (!checkingUI) airplay_app_check_for_updates();
}

- (void)toggleAutomaticUpdates:(id)sender
{
    (void)sender;
    if (checkingUI) return;
    BOOL requested = [automaticUpdatesCheckbox state] == NSControlStateValueOn;
    if (!airplay_app_set_automatic_updates_enabled(requested)) {
        /* The updater publishes the error; restore the actual saved selection. */
        [automaticUpdatesCheckbox setState:airplay_app_automatic_updates_enabled()
            ? NSControlStateValueOn : NSControlStateValueOff];
        return;
    }
    [self updatePreferencesState];
}

- (void)showLogs:(id)sender
{
    (void)sender;
    if (logFolder) [[NSWorkspace sharedWorkspace] openURL:[NSURL fileURLWithPath:logFolder isDirectory:YES]];
}
- (void)quit:(id)sender
{
    (void)sender;
    if (quitting) return;
    quitting=YES;
    if ([volumePopover isShown]) [volumePopover performClose:nil];
    ux_macos_airplay_window_save();
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self updateStatus];
    g_atomic_int_set(&quitRequested,1);
    g_printerr("AIRPLAY_APP requested normal receiver shutdown\n");
}
- (void)willTerminate:(NSNotification *)notification
{
    (void)notification;
    ux_macos_airplay_window_save();
    [[NSUserDefaults standardUserDefaults] synchronize];
}
@end

@implementation AirPlayApplication
- (BOOL)setActivationPolicy:(NSApplicationActivationPolicy)policy
{
    /* The Cocoa GL sink requests Regular again whenever it creates a window. */
    if (policy == NSApplicationActivationPolicyRegular)
        policy = NSApplicationActivationPolicyAccessory;
    return [super setActivationPolicy:policy];
}

- (void)terminate:(id)sender
{
    if (!g_atomic_int_get(&appActive)) {
        [super terminate:sender];
        return;
    }
    if (controller) [controller quit:sender];
    else g_atomic_int_set(&quitRequested,1);
    /* UxPlay's own loop stops Bonjour and the pipelines, then exits normally. */
}
@end

static int verify_ui(void)
{
    @try {
        [AirPlayApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        NSArray *languages = @[@"en",@"en-US",@"en-GB",@"en-CA",@"en-AU",
            @"es",@"es-ES",@"es-MX",@"es-AR",@"es-419"];
        for (NSString *language in languages) {
            @autoreleasepool {
                NSString *path = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:
                    [language stringByAppendingString:@".lproj"]];
                AirPlayController *probe = nil;
                @try {
                    uiCheckLocalization = [NSBundle bundleWithPath:path];
                    if (!uiCheckLocalization) {
                        fprintf(stderr,"AIRPLAY_UI_CHECK: missing localization %s\n",[language UTF8String]);
                        return 78;
                    }
                    probe = [[AirPlayController alloc] initForUICheck];
                    fprintf(stdout,"AIRPLAY_UI_CHECK: testing %s\n",[language UTF8String]);
                    if (![probe validateLayouts]) return 78;
                    fprintf(stdout,"AIRPLAY_UI_CHECK OK: %s preferences and volume layouts\n",[language UTF8String]);
                } @finally {
                    [probe release];
                    uiCheckLocalization = nil;
                }
            }
        }
    } @catch (NSException *exception) {
        fprintf(stderr,"AIRPLAY_UI_CHECK: %s: %s\n",[[exception name] UTF8String],[[exception reason] UTF8String]);
        return 78;
    }
    return 0;
}

static int verify_bundle(NSString *configuration)
{
    if (!configuration || ![[NSFileManager defaultManager] isReadableFileAtPath:configuration]) {
        fprintf(stderr,"AIRPLAY_CHECK: receiver.conf is missing\n");
        return 78;
    }
    NSArray *languages = @[@"en",@"en-US",@"en-GB",@"en-CA",@"en-AU",
        @"es",@"es-ES",@"es-MX",@"es-AR",@"es-419"];
    for (NSString *language in languages) {
        NSString *folder = [[[NSBundle mainBundle] resourcePath] stringByAppendingPathComponent:
            [language stringByAppendingString:@".lproj"]];
        NSString *path = [folder stringByAppendingPathComponent:@"Localizable.strings"];
        NSDictionary *strings = [NSDictionary dictionaryWithContentsOfFile:path];
        NSBundle *localized = [NSBundle bundleWithPath:folder];
        NSString *expected = [language hasPrefix:@"es"] ? @"Volumen" : @"Volume";
        if (![[strings objectForKey:@"Volume"] isEqualToString:expected] ||
            ![[localized localizedStringForKey:@"Volume" value:nil table:@"Localizable"] isEqualToString:expected]) {
            fprintf(stderr,"AIRPLAY_CHECK: invalid localization %s\n",[language UTF8String]);
            return 78;
        }
    }
    GError *error=NULL;
    if (!gst_init_check(NULL,NULL,&error)) {
        fprintf(stderr,"AIRPLAY_CHECK: %s\n",error ? error->message : "GStreamer could not start");
        if (error) g_error_free(error);
        return 78;
    }
    const char *required[]={"volume","audioconvert","glimagesink","osxaudiosink","avdec_aac","avdec_alac",
        "h264parse","decodebin","videoconvert","videoscale","appsrc","queue"};
    for (const char *name : required) {
        GstElementFactory *factory=gst_element_factory_find(name);
        if (!factory) {
            fprintf(stderr,"AIRPLAY_CHECK: missing GStreamer element %s\n",name);
            return 78;
        }
        gst_object_unref(factory);
    }
    fprintf(stdout,"AIRPLAY_CHECK OK: bundle resources and required GStreamer elements available\n");
    return 0;
}

int airplay_app_prepare(int *argc, char ***argv)
{
    @autoreleasepool {
        BOOL check=*argc == 2 && strcmp((*argv)[1],"--airplay-check") == 0;
        BOOL uiCheck=*argc == 2 && strcmp((*argv)[1],"--airplay-ui-check") == 0;
        NSBundle *bundle=[NSBundle mainBundle];
        BOOL bundled=[[bundle bundleIdentifier] isEqualToString:AppID];
        if (!bundled) {
            if (check || uiCheck) { fprintf(stderr,"AIRPLAY_CHECK: run from the AirPlay.app bundle\n"); return 78; }
            return -1; /* Preserve ordinary command-line use outside the app bundle. */
        }
        NSString *configuration=[bundle pathForResource:@"receiver" ofType:@"conf"];
        if (check) return verify_bundle(configuration);
        if (uiCheck) return verify_ui();
        [AirPlayApplication sharedApplication];
        [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
        if (!configuration || ![[NSFileManager defaultManager] isReadableFileAtPath:configuration]) {
            show_error(L(@"AirPlay is incomplete"), L(@"Run the installer again to restore its configuration."));
            return 78;
        }
        NSError *error=nil;
        NSString *support=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/AirPlay"];
        NSString *cache=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Caches/local.chevy.airplay"];
        NSString *logs=[NSHomeDirectory() stringByAppendingPathComponent:@"Library/Logs/AirPlay"];
        if (!ensure_directory(support,&error) || !ensure_directory(cache,&error) || !ensure_directory(logs,&error)) {
            show_error(L(@"AirPlay couldn’t prepare its files"), [error localizedDescription]);
            return 73;
        }
        NSString *lockPath=[support stringByAppendingPathComponent:@"receiver.lock"];
        instanceLock=open([lockPath fileSystemRepresentation],O_RDWR|O_CREAT|O_NOFOLLOW,0600);
        if (instanceLock < 0) { show_error(L(@"Couldn’t open AirPlay"), L(@"Couldn’t prepare the application lock.")); return 73; }
        if (flock(instanceLock,LOCK_EX|LOCK_NB) != 0) {
            int lockError=errno;
            close(instanceLock); instanceLock=-1;
            if (lockError != EWOULDBLOCK && lockError != EAGAIN) {
                show_error(L(@"Couldn’t open AirPlay"), L(@"Couldn’t check whether AirPlay is already running."));
                return 73;
            }
            return 0;
        }
        logFolder=[logs copy];
        NSString *log=[logs stringByAppendingPathComponent:@"AirPlay.log"];
        NSString *previous=[logs stringByAppendingPathComponent:@"AirPlay-anterior.log"];
        NSFileManager *fm=[NSFileManager defaultManager];
        if ([fm fileExistsAtPath:log]) {
            [fm removeItemAtPath:previous error:NULL];
            if (![fm moveItemAtPath:log toPath:previous error:&error]) {
                show_error(L(@"Couldn’t prepare the log"), [error localizedDescription]); return 73;
            }
        }
        if (!freopen([log fileSystemRepresentation],"a",stdout) || dup2(fileno(stdout),STDERR_FILENO)<0) return 73;
        chmod([log fileSystemRepresentation],0600);
        setvbuf(stdout,NULL,_IOLBF,0);
        setvbuf(stderr,NULL,_IONBF,0);
        freopen("/dev/null","r",stdin);
        NSString *registry=[cache stringByAppendingPathComponent:@"gstreamer-registry-x86_64.bin"];
        setenv("GST_REGISTRY",[registry fileSystemRepresentation],1);
        setenv("GST_DEBUG","2",1);
        setenv("GST_DEBUG_NO_COLOR","1",1);
        runningName=[saved_name() copy];
        static std::vector<std::string> arguments;
        static std::vector<char *> pointers;
        arguments={(*argv)[0],"-rc",[configuration fileSystemRepresentation],
            "-n",[runningName UTF8String],"-nh","-s","1920x1080","-fps","30",
            "-vsync","no","-vs","glimagesink force-aspect-ratio=true","-as","osxaudiosink"};
        pointers.clear();
        for (std::string &arg : arguments) pointers.push_back(const_cast<char *>(arg.c_str()));
        pointers.push_back(NULL);
        *argc=(int)arguments.size();
        *argv=pointers.data();
        /* Restore attenuation before gst_macos_main can start the receiver worker. */
        audio_renderer_set_local_volume([[NSUserDefaults standardUserDefaults] boolForKey:MutedKey]
            ? 0.0 : saved_local_volume());
        g_atomic_int_set(&appActive,1);
        fprintf(stderr,"AIRPLAY_APP launch name=%s bundle=%s\n",[runningName UTF8String],[[bundle bundlePath] fileSystemRepresentation]);
        return -1;
    }
}

static void install_on_main(void *)
{
    @autoreleasepool {
        if (!controller) {
            controller=[[AirPlayController alloc] init];
            [controller install];
            if (g_atomic_int_get(&quitRequested)) [controller quit:nil];
        }
    }
}
void airplay_app_install(void)
{
    if (g_atomic_int_get(&appActive)) dispatch_async_f(dispatch_get_main_queue(),NULL,install_on_main);
}
static void ready_on_main(void *)
{
    @autoreleasepool { [controller receiverReady]; }
}
void airplay_app_receiver_ready(void)
{
    if (g_atomic_int_get(&appActive)) {
        g_printerr("AIRPLAY_APP receiver ready name=%s\n",[runningName UTF8String]);
        dispatch_async_f(dispatch_get_main_queue(),NULL,ready_on_main);
    }
}
gboolean airplay_app_should_quit(void)
{
    return g_atomic_int_get(&appActive) && g_atomic_int_get(&quitRequested);
}

/* Called from receiver threads. Cache the newest state; all AppKit work stays on main. */
static void source_activity_on_main(void *)
{
    g_atomic_int_set(&sourceUpdatePending,0);
    @autoreleasepool { [controller sourceActivityChanged]; }
}
void airplay_app_source_active(gboolean active)
{
    g_atomic_int_set(&sourceActive,active ? 1 : 0);
    if (g_atomic_int_get(&appActive) &&
        g_atomic_int_compare_and_exchange(&sourceUpdatePending,0,1))
        dispatch_async_f(dispatch_get_main_queue(),NULL,source_activity_on_main);
}

/* Updater callbacks may originate off main; the borrowed version is copied immediately. */
struct AirPlayUpdateNotice {
    AirPlayUpdateState state;
    gchar *version;
};
static void update_state_on_main(void *data)
{
    AirPlayUpdateNotice *notice = static_cast<AirPlayUpdateNotice *>(data);
    @autoreleasepool {
        NSString *version = notice->version ? [NSString stringWithUTF8String:notice->version] : nil;
        [controller receiveUpdateState:notice->state version:version];
    }
    g_free(notice->version);
    g_free(notice);
}
void airplay_app_update_state(AirPlayUpdateState state, const char *version)
{
    if (!g_atomic_int_get(&appActive)) return;
    AirPlayUpdateNotice *notice = g_new0(AirPlayUpdateNotice,1);
    notice->state = state;
    notice->version = g_strdup(version);
    dispatch_async_f(dispatch_get_main_queue(),notice,update_state_on_main);
}
