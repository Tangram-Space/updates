// SPDX-License-Identifier: GPL-3.0-or-later
// Compile the production updater unchanged. Only the UI-state recipient is an
// observer; Sparkle, its scheduler, signature checks, and standard UI are real.
#ifndef AIRPLAY_UPDATER_IMPLEMENTATION
#error Compile with the path to the production app_updater.mm
#endif
#include AIRPLAY_UPDATER_IMPLEMENTATION
#include <cmath>

static NSMutableArray *CheckEvents;
static AirPlayUpdateState CheckState = AIRPLAY_UPDATE_NOT_CONFIGURED;
static NSString *CheckVersion;

extern "C" void airplay_app_update_state(AirPlayUpdateState state, const char *version)
{
    CheckState = state;
    CheckVersion = version ? [NSString stringWithUTF8String:version] : nil;
    if (CheckEvents) [CheckEvents addObject:@{@"state": @(state), @"version": CheckVersion ?: @""}];
}

static void Require(BOOL condition, NSString *message)
{
    if (!condition) @throw [NSException exceptionWithName:@"AirPlayUpdaterCheckFailure"
                                                  reason:message userInfo:nil];
}

static NSArray<NSWindow *> *VisibleWindows(void)
{
    NSMutableArray *windows = [NSMutableArray array];
    for (NSWindow *window in NSApp.windows) if (window.visible) [windows addObject:window];
    return windows;
}

static void Pump(void)
{
    NSEvent *event = [NSApp nextEventMatchingMask:NSEventMaskAny
                                       untilDate:[NSDate dateWithTimeIntervalSinceNow:0.025]
                                          inMode:NSDefaultRunLoopMode dequeue:YES];
    if (event) [NSApp sendEvent:event];
    [NSApp updateWindows];
}

static void Wait(BOOL (^condition)(void), NSTimeInterval timeout, NSString *failure)
{
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout];
    while (!condition() && deadline.timeIntervalSinceNow > 0) Pump();
    Require(condition(), failure);
}

static SPUUpdater *RealUpdater(void)
{
    return [airplayUpdater valueForKey:@"updater"];
}

static NSWindowController *RealAlert(void)
{
    SPUStandardUserDriver *driver = [airplayUpdater valueForKey:@"userDriver"];
    return [driver valueForKey:@"activeUpdateAlert"];
}

static void CheckPolicy(BOOL automatic)
{
    SPUUpdater *updater = RealUpdater();
    Require([updater isKindOfClass:[SPUUpdater class]], @"The real Sparkle updater was not initialized.");
    Require(updater.automaticallyChecksForUpdates == automatic, @"Sparkle scheduling differs from the saved opt-in.");
    Require(!updater.automaticallyDownloadsUpdates, @"Automatic downloads must remain disabled.");
    Require(!updater.allowsAutomaticUpdates, @"The fixture unexpectedly permits automatic installation.");
    Require(!updater.sendsSystemProfile, @"System-profile sending must remain disabled.");
    Require(fabs(updater.updateCheckInterval - 86400.0) < 0.01, @"The scheduled interval must be one day.");
    Require(airplayUpdater.supportsGentleScheduledUpdateReminders, @"The actual delegate does not declare gentle reminders.");
}

static void WaitForRealUpdate(BOOL visible)
{
    Wait(^BOOL {
        NSWindowController *alert = RealAlert();
        return CheckState == AIRPLAY_UPDATE_AVAILABLE && alert != nil &&
               alert.window.visible == visible && airplay_app_updater_can_check();
    }, 60, visible ? @"The explicit check did not show Sparkle's real update alert."
                  : @"The scheduled check did not reach a hidden real Sparkle update alert.");
    SUAppcastItem *item = [RealAlert() valueForKey:@"updateItem"];
    Require([item isKindOfClass:[SUAppcastItem class]], @"The real alert has no appcast item.");
    Require(item.signingValidationStatus == SPUAppcastSigningValidationStatusSucceeded,
            @"Sparkle did not validate the public feed signature.");
    Require([item.fileURL.absoluteString hasPrefix:@"https://github.com/Tangram-Space/updates/releases/download/airplay-v"],
            @"The selected update does not belong to the AirPlay release channel.");
    Require(item.contentLength > 0 && !item.informationOnlyUpdate,
            @"The public feed did not select an installable release.");
}

static void DismissWithoutInstalling(void)
{
    NSWindow *window = RealAlert().window;
    Require(window != nil && window.visible, @"There is no visible standard alert to close.");
    // Exercise the standard window close action. Never choose Install/Download.
    [window performClose:nil];
    Wait(^BOOL {
        return !RealUpdater().sessionInProgress && RealAlert() == nil &&
               VisibleWindows().count == 0;
    }, 10, @"Closing the standard update alert did not finish the session.");
    Require(CheckState == AIRPLAY_UPDATE_IDLE, @"The available-update reminder was not cleared after dismissal.");
}

int main(int argc, const char *argv[])
{
    @autoreleasepool {
        NSMutableDictionary *report = [NSMutableDictionary dictionaryWithDictionary:@{
            @"schema": @1, @"status": @"FAIL", @"real_production_updater": @YES,
            @"real_sparkle_standard_driver": @YES, @"installation_requested": @NO
        }];
        int status = 1;
        NSString *output = NSProcessInfo.processInfo.environment[@"AIRPLAY_UPDATER_CHECK_RESULT"];
        CheckEvents = [NSMutableArray array];
        @try {
            Require(argc == 2, @"Usage: UpdaterCheck default-opt-in|restored-opt-in|restored-off");
            NSString *phase = [NSString stringWithUTF8String:argv[1]];
            NSBundle *bundle = NSBundle.mainBundle;
            NSString *identifier = bundle.bundleIdentifier;
            Require([identifier hasPrefix:@"local.chevy.airplay.updatercheck."] &&
                    [[bundle objectForInfoDictionaryKey:@"AirPlayUpdaterPolicyCheck"] isEqual:@YES],
                    @"This harness must run only in its dedicated fixture bundle.");
            Require(output.length > 0, @"A dedicated report path is required.");
            report[@"phase"] = phase;
            report[@"fixture_bundle_identifier"] = identifier;
            [NSApplication sharedApplication];
            [NSApp setActivationPolicy:NSApplicationActivationPolicyAccessory];
            [NSApp finishLaunching];
            NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;

            if ([phase isEqualToString:@"default-opt-in"]) {
                [defaults removePersistentDomainForName:identifier];
                // Stale Sparkle preferences must not opt a manual-only user in.
                [defaults setBool:YES forKey:@"SUEnableAutomaticChecks"];
                Require(!airplay_app_automatic_updates_enabled(), @"A fresh app must default to manual checks.");
                Require(airplayUpdater == nil, @"A preference read unexpectedly initialized the owner.");
                airplay_app_updater_initialize();
                Require(airplay_app_updater_configured(), @"The bundled channel was not recognized.");
                Require(!airplay_app_automatic_updates_enabled() && RealUpdater() == nil,
                        @"A legacy Sparkle preference started background checks without app opt-in.");
                Require(VisibleWindows().count == 0, @"Initialization raised a window while opt-in was off.");
                Require(airplay_app_set_automatic_updates_enabled(true), @"Enabling automatic checks failed.");
                Require(airplay_app_automatic_updates_enabled(), @"The checkbox opt-in was not saved.");
                CheckPolicy(YES);
                Require([defaults synchronize], @"The opt-in preference could not be synchronized.");
                report[@"legacy_sparkle_default_did_not_enable_scheduling"] = @YES;
                report[@"opt_in_persisted"] = @YES;
            } else if ([phase isEqualToString:@"restored-opt-in"]) {
                Require(airplay_app_automatic_updates_enabled(), @"Opt-in was not retained across processes.");
                Require(airplayUpdater == nil, @"A saved-preference read unexpectedly initialized Sparkle.");
                // Force no timing state only in this isolated test domain, as
                // documented by Sparkle. The normal updater starts the cycle.
                [defaults removeObjectForKey:@"SULastCheckTime"];
                BOOL activeBefore = NSApp.active;
                airplay_app_updater_initialize();
                CheckPolicy(YES);
                WaitForRealUpdate(NO);
                NSDate *quietDeadline = [NSDate dateWithTimeIntervalSinceNow:1.0];
                while (quietDeadline.timeIntervalSinceNow > 0) {
                    Pump();
                    Require(VisibleWindows().count == 0, @"A scheduled update raised a window.");
                    Require(NSApp.active == activeBefore, @"A scheduled update changed application activation.");
                }
                report[@"scheduled_signed_update_version"] = CheckVersion ?: @"";
                report[@"scheduled_update_visible_windows"] = @(VisibleWindows().count);
                report[@"scheduled_update_did_not_activate_app"] = @YES;
                Require(airplay_app_updater_can_check(), @"Manual check is unavailable while a gentle reminder is pending.");
                airplay_app_check_for_updates();
                WaitForRealUpdate(YES);
                report[@"manual_action_showed_standard_alert"] = @YES;
                DismissWithoutInstalling();
                report[@"dismissal_cleared_available_state"] = @YES;
                Require(airplay_app_set_automatic_updates_enabled(false), @"Disabling automatic checks failed.");
                Require(!airplay_app_automatic_updates_enabled(), @"The saved opt-in remained enabled.");
                CheckPolicy(NO);
                Require([defaults synchronize], @"The disabled preference could not be synchronized.");
            } else if ([phase isEqualToString:@"restored-off"]) {
                Require(!airplay_app_automatic_updates_enabled(), @"Opt-out was not retained across processes.");
                airplay_app_updater_initialize();
                Require(RealUpdater() == nil, @"An opted-out restart initialized Sparkle scheduling.");
                Require(VisibleWindows().count == 0, @"An opted-out restart raised a window.");
                Require(airplay_app_updater_can_check(), @"Manual checking is disabled after opting out.");
                airplay_app_check_for_updates();
                CheckPolicy(NO);
                WaitForRealUpdate(YES);
                DismissWithoutInstalling();
                report[@"manual_check_works_after_persisted_opt_out"] = @YES;
                Require(!airplay_app_automatic_updates_enabled(), @"A manual check silently enabled automatic checks.");
                [defaults removePersistentDomainForName:identifier];
                [defaults synchronize];
            } else {
                Require(NO, @"Unknown test phase.");
            }
            report[@"status"] = @"PASS";
            report[@"final_state"] = @(CheckState);
            status = 0;
        } @catch (NSException *error) {
            report[@"error"] = error.reason ?: error.name;
            fprintf(stderr, "UPDATER_CHECK FAIL: %s\n", [report[@"error"] UTF8String]);
        }
        report[@"events"] = CheckEvents;
        if (output.length) {
            NSError *error = nil;
            NSData *encoded = [NSJSONSerialization dataWithJSONObject:report
                                                            options:NSJSONWritingPrettyPrinted error:&error];
            if (!encoded || ![encoded writeToFile:output options:NSDataWritingAtomic error:&error]) {
                fprintf(stderr, "UPDATER_CHECK report write failed\n");
                return 1;
            }
        }
        if (status == 0) fprintf(stdout, "UPDATER_CHECK PASS: %s\n", argv[1]);
        return status;
    }
}
