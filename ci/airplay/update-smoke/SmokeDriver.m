// SPDX-License-Identifier: GPL-3.0-or-later
// Synthetic test application A. This is not the AirPlay receiver executable.
// It exercises only public Sparkle 2.9.6 APIs, updating its own main bundle.
#import <Cocoa/Cocoa.h>
#import <Sparkle/Sparkle.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static void Record(NSString *event, NSDictionary *details)
{
    NSMutableDictionary *record = [NSMutableDictionary dictionaryWithDictionary:details ?: @{}];
    record[@"event"] = event;
    record[@"pid"] = @(getpid());
    record[@"time"] = @([[NSDate date] timeIntervalSince1970]);
    NSData *data = [NSJSONSerialization dataWithJSONObject:record options:0 error:NULL];
    if (data) {
        fwrite(data.bytes, 1, data.length, stdout);
        fputc('\n', stdout);
        fflush(stdout);
    }
}

static void Fail(NSString *reason, NSError *error)
{
    NSMutableDictionary *details = [NSMutableDictionary dictionaryWithObject:reason forKey:@"reason"];
    if (error) {
        details[@"domain"] = error.domain;
        details[@"code"] = @(error.code);
        details[@"description"] = error.localizedDescription;
    }
    Record(@"failure", details);
    exit(1);
}

@interface SmokeDriver : NSObject <NSApplicationDelegate, SPUUpdaterDelegate, SPUUserDriver>
@property(nonatomic, strong) SPUUpdater *updater;
@property(nonatomic, copy) NSString *targetVersion;
@property(nonatomic, copy) NSString *targetURL;
@property(nonatomic, copy) NSString *feedURL;
@property(nonatomic) uint64_t targetLength;
@property(nonatomic) BOOL checkStarted;
@property(nonatomic) BOOL installRequested;
@property(nonatomic) uint64_t receivedBytes;
@end

@implementation SmokeDriver
- (void)applicationDidFinishLaunching:(NSNotification *)notification
{
    (void)notification;
    NSBundle *bundle = [NSBundle mainBundle];
    NSDictionary *info = bundle.infoDictionary;
    if (![info[@"AirPlayUpdateSmokeFixture"] isEqual:@YES] ||
        ![bundle.bundleIdentifier isEqualToString:@"local.chevy.airplay"] ||
        ![info[@"SURequireSignedFeed"] isEqual:@YES] ||
        ![info[@"SUVerifyUpdateBeforeExtraction"] isEqual:@YES]) {
        Fail(@"Refusing to run outside the isolated, signed-feed test fixture.", nil);
    }
    self.targetVersion = info[@"AirPlaySmokeTargetBuild"];
    self.targetURL = info[@"AirPlaySmokeTargetArchiveURL"];
    self.feedURL = info[@"SUFeedURL"];
    self.targetLength = [info[@"AirPlaySmokeTargetArchiveBytes"] unsignedLongLongValue];
    if (!self.targetVersion.length || !self.targetURL.length || !self.feedURL.length || !self.targetLength) {
        Fail(@"The test fixture has incomplete target metadata.", nil);
    }
    [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
    self.updater = [[SPUUpdater alloc] initWithHostBundle:bundle
                                     applicationBundle:bundle
                                            userDriver:self delegate:self];
    NSError *error = nil;
    if (![self.updater startUpdater:&error]) Fail(@"Sparkle could not start.", error);
    Record(@"started", @{@"fixture": @"synthetic-A", @"host_is_main_bundle": @YES,
                         @"bundle": bundle.bundlePath,
                         @"source_build": info[@"CFBundleVersion"],
                         @"target_build": self.targetVersion});
    [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(beginCheck:)
                                  userInfo:nil repeats:YES];
    [NSTimer scheduledTimerWithTimeInterval:300.0 target:self selector:@selector(watchdog:)
                                  userInfo:nil repeats:NO];
}

- (void)beginCheck:(NSTimer *)timer
{
    if (self.checkStarted) { [timer invalidate]; return; }
    if (!self.updater.canCheckForUpdates) return;
    self.checkStarted = YES;
    [timer invalidate];
    Record(@"checking", nil);
    [self.updater checkForUpdates];
}

- (void)watchdog:(NSTimer *)timer
{
    (void)timer;
    Fail(@"The synthetic updater exceeded its five-minute deadline.", nil);
}

- (NSApplicationTerminateReply)applicationShouldTerminate:(NSApplication *)sender
{
    (void)sender;
    Record(@"application_should_terminate", @{@"install_requested": @(self.installRequested)});
    return NSTerminateNow;
}

- (void)applicationWillTerminate:(NSNotification *)notification
{
    (void)notification;
    Record(@"application_will_terminate", @{@"install_requested": @(self.installRequested)});
}

- (NSString *)feedURLStringForUpdater:(SPUUpdater *)updater
{ (void)updater; return self.feedURL; }
- (BOOL)updaterShouldPromptForPermissionToCheckForUpdates:(SPUUpdater *)updater
{ (void)updater; return NO; }
- (NSArray<NSString *> *)allowedSystemProfileKeysForUpdater:(SPUUpdater *)updater
{ (void)updater; return @[]; }
- (BOOL)updater:(SPUUpdater *)updater mayPerformUpdateCheck:(SPUUpdateCheck)check error:(NSError **)error
{ (void)updater; (void)error; return check == SPUUpdateCheckUpdates; }

- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply
{
    (void)request;
    Record(@"permission_request", nil);
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation
{ (void)cancellation; Record(@"user_initiated_check", nil); }

- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state
                               reply:(void (^)(SPUUserUpdateChoice))reply
{
    if (![item.versionString isEqualToString:self.targetVersion] ||
        ![item.fileURL.absoluteString isEqualToString:self.targetURL] ||
        item.contentLength != self.targetLength || item.informationOnlyUpdate ||
        item.signingValidationStatus != SPUAppcastSigningValidationStatusSucceeded) {
        reply(SPUUserUpdateChoiceDismiss);
        Fail(@"The signed feed did not select the exact expected release.", nil);
    }
    Record(@"update_found", @{@"build": item.versionString, @"url": item.fileURL.absoluteString,
                               @"signed_feed_validated": @YES, @"stage": @(state.stage)});
    reply(SPUUserUpdateChoiceInstall);
}

- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data
{ (void)data; Record(@"release_notes_received", nil); }
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error
{ Record(@"release_notes_failed", @{@"domain": error.domain, @"code": @(error.code)}); }
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement
{ acknowledgement(); Fail(@"The required target update was not found.", error); }
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement
{ acknowledgement(); Fail(@"Sparkle reported an update error.", error); }
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation
{ (void)cancellation; Record(@"download_started", nil); }
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length
{ Record(@"download_length", @{@"bytes": @(length)}); }
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length
{ self.receivedBytes += length; }
- (void)showDownloadDidStartExtractingUpdate
{ Record(@"extracting", @{@"received_bytes": @(self.receivedBytes)}); }
- (void)showExtractionReceivedProgress:(double)progress
{ (void)progress; }
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply
{
    self.installRequested = YES;
    Record(@"install_requested", @{@"relaunch": @YES});
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated
                          retryTerminatingApplication:(void (^)(void))retry
{ (void)retry; Record(@"installing", @{@"application_terminated": @(terminated)}); }
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement
{ Record(@"driver_install_finished", @{@"relaunched": @(relaunched)}); acknowledgement(); }
- (void)dismissUpdateInstallation
{ Record(@"installation_dismissed", nil); }
@end

int main(int argc, const char *argv[])
{
    (void)argv;
    if (argc != 1) return 64;
    setvbuf(stdout, NULL, _IONBF, 0);
    @autoreleasepool {
        @try {
            NSApplication *application = [NSApplication sharedApplication];
            __attribute__((objc_precise_lifetime)) SmokeDriver *driver = [[SmokeDriver alloc] init];
            application.delegate = driver;
            [application run];
        } @catch (NSException *exception) {
            Record(@"exception", @{@"name": exception.name, @"reason": exception.reason ?: @""});
            return 1;
        }
    }
    return 0;
}
