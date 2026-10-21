/* Sparkle is compiled with ARC in this file only. The AppKit controller and
 * GStreamer bridge keep their existing memory-management and lifecycle. */
#import <Cocoa/Cocoa.h>

/* Sparkle 2.9.6 is binary-compatible with Big Sur, but its public headers were
 * built with a newer SDK. These annotations affect Swift import only. */
#ifndef NS_SWIFT_UI_ACTOR
#define NS_SWIFT_UI_ACTOR
#endif
#ifndef NS_SWIFT_SENDABLE
#define NS_SWIFT_SENDABLE
#endif
#ifndef NS_SWIFT_ASYNC
#define NS_SWIFT_ASYNC(...)
#endif
#import <Sparkle/Sparkle.h>

#include "app_updater.h"
#include "app_controller.h"

static void *AirPlayCanCheckContext = &AirPlayCanCheckContext;
static NSString *const AutomaticChecksKey = @"AirPlay.AutomaticUpdateChecks";
static const NSTimeInterval AutomaticCheckInterval = 24.0 * 60.0 * 60.0;

static BOOL true_number(id value)
{
    return [value isKindOfClass:[NSNumber class]] && [value boolValue];
}

/* The endpoint is public, fixed in the signed bundle, and carries no login
 * credentials. Sparkle verifies both the feed and update archive with EdDSA. */
static NSString *validated_feed(NSBundle *bundle)
{
    id value = [bundle objectForInfoDictionaryKey:@"SUFeedURL"];
    if (![value isKindOfClass:[NSString class]] || ![value length]) return nil;
    NSURLComponents *parts = [NSURLComponents componentsWithString:value];
    if (!parts || ![parts.scheme.lowercaseString isEqualToString:@"https"] ||
        !parts.host.length || !parts.path.length || parts.user != nil ||
        parts.password != nil || parts.query != nil || parts.fragment != nil ||
        !parts.URL || ![parts.URL.absoluteString isEqualToString:value]) return nil;

    id key = [bundle objectForInfoDictionaryKey:@"SUPublicEDKey"];
    if (![key isKindOfClass:[NSString class]]) return nil;
    NSData *decoded = [[NSData alloc] initWithBase64EncodedString:key options:0];
    if (decoded.length != 32 || ![[decoded base64EncodedStringWithOptions:0] isEqualToString:key]) return nil;
    if (!true_number([bundle objectForInfoDictionaryKey:@"SURequireSignedFeed"]) ||
        !true_number([bundle objectForInfoDictionaryKey:@"SUVerifyUpdateBeforeExtraction"])) return nil;
    return [value copy];
}

@interface AirPlayUpdater : NSObject <SPUUpdaterDelegate, SPUStandardUserDriverDelegate> {
    NSString *_feed;
    NSString *_availableVersion;
    SPUUpdater *_updater;
    SPUStandardUserDriver *_userDriver;
    AirPlayUpdateState _state;
    BOOL _observing;
}
- (BOOL)canCheck;
- (BOOL)configured;
- (BOOL)automaticChecksEnabled;
- (BOOL)setAutomaticChecksEnabled:(BOOL)enabled;
- (BOOL)startIfNeeded;
- (void)startScheduledChecksIfEnabled;
- (void)publishState;
- (void)check;
@end

@implementation AirPlayUpdater
- (instancetype)init
{
    self = [super init];
    if (self) {
        _feed = validated_feed([NSBundle mainBundle]);
        _state = _feed ? AIRPLAY_UPDATE_IDLE : AIRPLAY_UPDATE_NOT_CONFIGURED;
    }
    return self;
}

- (void)dealloc
{
    if (_observing) {
        [_updater removeObserver:self forKeyPath:@"canCheckForUpdates" context:AirPlayCanCheckContext];
    }
}

- (BOOL)canCheck
{
    return _feed != nil && (_updater == nil || _updater.canCheckForUpdates);
}

- (BOOL)configured
{
    return _feed != nil;
}

- (BOOL)automaticChecksEnabled
{
    /* An app-owned preference prevents an old Sparkle default from opting a
     * previously manual-only installation into background network requests. */
    return _feed != nil && true_number([[NSUserDefaults standardUserDefaults]
                                        objectForKey:AutomaticChecksKey]);
}

- (void)publishState
{
    /* app_controller copies this borrowed UTF-8 string before dispatching. */
    airplay_app_update_state(_state, _availableVersion.UTF8String);
}

- (void)setState:(AirPlayUpdateState)state version:(NSString *)version
{
    _state = state;
    _availableVersion = [version copy];
    [self publishState];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object
                       change:(NSDictionary<NSKeyValueChangeKey,id> *)change
                      context:(void *)context
{
    if (context == AirPlayCanCheckContext && object == _updater) {
        /* Revalidate the button when Sparkle becomes ready, without turning a
         * failed, incompatible or unfinished check into "up to date". */
        [self publishState];
    } else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

- (BOOL)startIfNeeded
{
    if (!_feed) {
        [self setState:AIRPLAY_UPDATE_NOT_CONFIGURED version:nil];
        return NO;
    }

    if (!_updater) {
        NSBundle *bundle = [NSBundle mainBundle];
        _userDriver = [[SPUStandardUserDriver alloc] initWithHostBundle:bundle delegate:self];
        _updater = [[SPUUpdater alloc] initWithHostBundle:bundle applicationBundle:bundle
                                              userDriver:_userDriver delegate:self];
        /* Sparkle owns scheduling, last-check persistence, and wake handling.
         * Opt-in permits feed checks only; installation always needs a user. */
        _updater.automaticallyChecksForUpdates = [self automaticChecksEnabled];
        _updater.updateCheckInterval = AutomaticCheckInterval;
        _updater.automaticallyDownloadsUpdates = NO;
        _updater.sendsSystemProfile = NO;
        [_updater addObserver:self forKeyPath:@"canCheckForUpdates" options:0 context:AirPlayCanCheckContext];
        _observing = YES;
        NSError *error = nil;
        if (![_updater startUpdater:&error]) {
            [_updater removeObserver:self forKeyPath:@"canCheckForUpdates" context:AirPlayCanCheckContext];
            _observing = NO;
            _updater = nil;
            _userDriver = nil;
            NSLog(@"AirPlay update startup failed: %@ (%ld)", error.domain, (long)error.code);
            [self setState:AIRPLAY_UPDATE_ERROR version:nil];
            return NO;
        }
    }
    return YES;
}

- (void)startScheduledChecksIfEnabled
{
    if ([self automaticChecksEnabled]) [self startIfNeeded];
}

- (BOOL)setAutomaticChecksEnabled:(BOOL)enabled
{
    if (!_feed) return NO;
    /* Start while the previous preference is still in force so a setup error
     * cannot falsely save an enabled checkbox. The property setter schedules
     * the new cycle after opt-in; no custom polling timer is needed. */
    if (enabled && ![self startIfNeeded]) return NO;
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:AutomaticChecksKey];
    if (_updater) _updater.automaticallyChecksForUpdates = enabled;
    [self publishState];
    return YES;
}

- (void)check
{
    if (![self startIfNeeded]) return;

    if (!_updater.canCheckForUpdates) return;
    /* A second click can focus Sparkle's existing download/install window. */
    if (!_updater.sessionInProgress) [self setState:AIRPLAY_UPDATE_CHECKING version:nil];
    [_updater checkForUpdates];
}

- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater
{
    (void)updater;
    /* Do not accept a legacy feed URL override from UserDefaults. */
    return _feed;
}

- (BOOL)updaterShouldPromptForPermissionToCheckForUpdates:(SPUUpdater *)updater
{
    (void)updater;
    return NO;
}

- (NSArray<NSString *> *)allowedSystemProfileKeysForUpdater:(SPUUpdater *)updater
{
    (void)updater;
    return @[];
}

- (BOOL)updater:(SPUUpdater *)updater mayPerformUpdateCheck:(SPUUpdateCheck)updateCheck
          error:(NSError *__autoreleasing *)error
{
    (void)updater;
    (void)error;
    /* Also enforce opt-in at request time, including a cycle queued just
     * before the preference was disabled. Manual checks always remain usable. */
    return _feed != nil &&
        (updateCheck == SPUUpdateCheckUpdates ||
         (updateCheck == SPUUpdateCheckUpdatesInBackground && [self automaticChecksEnabled]));
}

- (BOOL)supportsGentleScheduledUpdateReminders
{
    return YES;
}

- (BOOL)standardUserDriverShouldHandleShowingScheduledUpdate:(SUAppcastItem *)update
                                        andInImmediateFocus:(BOOL)immediateFocus
{
    (void)update;
    (void)immediateFocus;
    /* A background receiver must not raise windows or take focus during a
     * stream. The menu and Preferences expose the available update instead. */
    return NO;
}

- (void)standardUserDriverWillHandleShowingUpdate:(BOOL)handleShowingUpdate
                                       forUpdate:(SUAppcastItem *)update
                                           state:(SPUUserUpdateState *)state
{
    (void)handleShowingUpdate;
    (void)state;
    [self setState:AIRPLAY_UPDATE_AVAILABLE version:update.displayVersionString];
}

- (void)standardUserDriverWillFinishUpdateSession
{
    /* Clear the gentle reminder if the user dismisses/skips the update.
     * A following failure callback can still publish its precise error state. */
    if (_state == AIRPLAY_UPDATE_AVAILABLE) [self setState:AIRPLAY_UPDATE_IDLE version:nil];
}

- (void)updater:(SPUUpdater *)updater didFindValidUpdate:(SUAppcastItem *)item
{
    (void)updater;
    [self setState:AIRPLAY_UPDATE_AVAILABLE version:item.displayVersionString];
}

- (void)recordNoUpdate:(NSError *)error
{
    NSNumber *reasonValue = error.userInfo[SPUNoUpdateFoundReasonKey];
    SPUNoUpdateFoundReason reason = [reasonValue isKindOfClass:[NSNumber class]] ?
        (SPUNoUpdateFoundReason)reasonValue.integerValue : SPUNoUpdateFoundReasonUnknown;
    switch (reason) {
        case SPUNoUpdateFoundReasonOnLatestVersion:
        case SPUNoUpdateFoundReasonOnNewerThanLatestVersion:
            [self setState:AIRPLAY_UPDATE_UP_TO_DATE version:nil];
            break;
        case SPUNoUpdateFoundReasonSystemIsTooOld:
        case SPUNoUpdateFoundReasonSystemIsTooNew:
        case SPUNoUpdateFoundReasonHardwareDoesNotSupportARM64:
            [self setState:AIRPLAY_UPDATE_UNSUPPORTED version:nil];
            break;
        case SPUNoUpdateFoundReasonUnknown:
        default:
            [self setState:AIRPLAY_UPDATE_ERROR version:nil];
            break;
    }
}

- (void)updaterDidNotFindUpdate:(SPUUpdater *)updater error:(NSError *)error
{
    (void)updater;
    [self recordNoUpdate:error];
}

- (void)recordError:(NSError *)error
{
    if ([error.domain isEqualToString:SUSparkleErrorDomain] && error.code == SUNoUpdateError) {
        [self recordNoUpdate:error];
    } else if (([error.domain isEqualToString:SUSparkleErrorDomain] &&
                (error.code == SUInstallationCanceledError || error.code == SUInstallationAuthorizeLaterError)) ||
               ([error.domain isEqualToString:NSURLErrorDomain] && error.code == NSURLErrorCancelled)) {
        [self setState:AIRPLAY_UPDATE_IDLE version:nil];
    } else {
        /* Sparkle's standard UI retains the detailed, localized error dialog.
         * Our status reports failure; it never guesses the installed version. */
        NSLog(@"AirPlay update failed: %@ (%ld)", error.domain, (long)error.code);
        [self setState:AIRPLAY_UPDATE_ERROR version:nil];
    }
}

- (void)updater:(SPUUpdater *)updater didAbortWithError:(NSError *)error
{
    (void)updater;
    [self recordError:error];
}

- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)updateCheck
          error:(NSError *)error
{
    (void)updater;
    if (updateCheck != SPUUpdateCheckUpdates &&
        updateCheck != SPUUpdateCheckUpdatesInBackground) return;
    if (error) {
        [self recordError:error];
    } else if (_state == AIRPLAY_UPDATE_CHECKING) {
        /* Cancellation or dismissal without an appcast result is not proof
         * that the installed build is current. */
        [self setState:AIRPLAY_UPDATE_IDLE version:nil];
    } else {
        [self publishState];
    }
}
@end

/* App-lifetime owner: Sparkle delegates are weak. Every access stays on main. */
static AirPlayUpdater *airplayUpdater;

void airplay_app_updater_initialize(void)
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ airplay_app_updater_initialize(); });
        return;
    }
    if (!airplayUpdater) {
        airplayUpdater = [[AirPlayUpdater alloc] init];
        [airplayUpdater startScheduledChecksIfEnabled];
    }
    [airplayUpdater publishState];
}

void airplay_app_check_for_updates(void)
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ airplay_app_check_for_updates(); });
        return;
    }
    if (!airplayUpdater) airplay_app_updater_initialize();
    [airplayUpdater check];
}

bool airplay_app_updater_can_check(void)
{
    return [NSThread isMainThread] && airplayUpdater && [airplayUpdater canCheck];
}

bool airplay_app_updater_configured(void)
{
    return [NSThread isMainThread] && airplayUpdater && [airplayUpdater configured];
}

bool airplay_app_automatic_updates_enabled(void)
{
    if (![NSThread isMainThread]) return false;
    if (airplayUpdater) return [airplayUpdater automaticChecksEnabled];
    /* Reading the saved preference must not create Sparkle or start a request. */
    return validated_feed([NSBundle mainBundle]) != nil &&
        true_number([[NSUserDefaults standardUserDefaults] objectForKey:AutomaticChecksKey]);
}

bool airplay_app_set_automatic_updates_enabled(bool enabled)
{
    if (![NSThread isMainThread]) return false;
    if (!airplayUpdater) airplay_app_updater_initialize();
    return [airplayUpdater setAutomaticChecksEnabled:enabled];
}
