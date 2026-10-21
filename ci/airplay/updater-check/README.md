# Native updater policy check

This check compiles the exact production app_updater.mm into a disposable Cocoa
fixture using the Sparkle 2.9.6 framework from the prepared release bundle. It
replaces only airplay_app_update_state with a recording observer. Sparkle's real
updater, scheduler, signed public feed verification, and standard user driver run
unchanged. No Install action is accepted and no screenshot or other image is made.

Three separate processes share only the fixture's UUID-named defaults domain:

1. A missing app opt-in remains disabled even with a stale Sparkle YES preference.
   The production public setter enables and saves the option.
2. A new process restores the option and lets Sparkle schedule its real signed
   public feed check. The available update stays in a hidden standard alert, with
   zero visible windows and no application activation. The explicit production
   check action brings that same alert into view. Its normal window-close action
   dismisses it and clears the available-update state. The option is then disabled.
3. Another process restores the disabled option without creating a scheduler.
   An explicit manual check still finds the signed update and shows its standard
   alert, which is closed without downloading or installing the update.

The daily interval, disabled automatic downloads/installation, and disabled system
profile reporting are asserted on the actual Sparkle instance. The fixture starts
at build 1 so the current public AirPlay feed supplies a newer real appcast item.
The original prepared app is checked for unchanged executable and Info.plist hashes.

Invocation on the existing Intel build runner, after bundle collection and before
release signing:

    xcrun python3 ci/airplay/updater-check/run-updater-check.py \
      --bundle "$AIRPLAY_CI_BUILD_DIR/bundle.noindex/AirPlay.app" \
      --output "$AIRPLAY_CI_ARTIFACT_DIR/updater-check"

Reports contain the source/harness digests, native OS/architecture, phase results,
state events and ordinary build/run logs. The test is not a receiver streaming,
system-login, sleep/wake, or Big Sur hardware test. The separate self-update smoke
test covers actual Sparkle installation and relaunch of the published archive.
