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

@interface AirPlayUpdater : NSObject <SPUUpdaterDelegate> {
    NSString *_feed;
    NSString *_availableVersion;
    SPUUpdater *_updater;
    SPUStandardUserDriver *_userDriver;
    AirPlayUpdateState _state;
    BOOL _observing;
}
- (BOOL)canCheck;
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

- (void)check
{
    if (!_feed) {
        [self setState:AIRPLAY_UPDATE_NOT_CONFIGURED version:nil];
        return;
    }

    if (!_updater) {
        NSBundle *bundle = [NSBundle mainBundle];
        _userDriver = [[SPUStandardUserDriver alloc] initWithHostBundle:bundle delegate:nil];
        _updater = [[SPUUpdater alloc] initWithHostBundle:bundle applicationBundle:bundle
                                              userDriver:_userDriver delegate:self];
        /* This version exposes manual checking only. Override any stale
         * Sparkle preference, and never prompt for automatic checking. */
        _updater.automaticallyChecksForUpdates = NO;
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
            return;
        }
    }

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
    /* A scheduling or information check must not introduce background network
     * activity into this manual-only UI, even if defaults were changed. */
    return _feed != nil && updateCheck == SPUUpdateCheckUpdates;
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
    if (updateCheck != SPUUpdateCheckUpdates) return;
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

/* App-lifetime owner: Sparkle delegates are weak. Every access stays on main,
 * and initialization does not create or start SPUUpdater. */
static AirPlayUpdater *airplayUpdater;

void airplay_app_updater_initialize(void)
{
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{ airplay_app_updater_initialize(); });
        return;
    }
    if (!airplayUpdater) airplayUpdater = [[AirPlayUpdater alloc] init];
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
