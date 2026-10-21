#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Test the real production updater and Sparkle UI in an isolated hosted-Mac app.

No production bundle/defaults are changed. No update installation is accepted.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shlex
import shutil
import subprocess
import sys
import tempfile
import uuid

FEED = 'https://raw.githubusercontent.com/Tangram-Space/updates/main/feeds/airplay/stable/appcast.xml'


def require(condition, message):
    if not condition:
        raise ValueError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(arguments, log, *, env=None, timeout=120):
    with log.open('ab') as stream:
        completed = subprocess.run([str(value) for value in arguments], stdout=stream,
                                   stderr=subprocess.STDOUT, env=env, timeout=timeout)
    require(completed.returncode == 0, 'Command failed; inspect ' + log.name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    arguments = parser.parse_args()
    require(sys.platform == 'darwin', 'This check requires the native macOS runner.')
    require(os.environ.get('GITHUB_ACTIONS') == 'true' and
            os.environ.get('GITHUB_REPOSITORY') == 'Tangram-Space/updates',
            'Run this isolated check only in the reviewed public repository CI.')
    runner_temp = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    bundle = arguments.bundle.resolve(strict=True)
    bundle.relative_to(runner_temp)
    output = arguments.output.absolute()
    require(not output.exists() and not output.is_symlink(), 'The report directory must be new.')
    output.parent.resolve(strict=True).relative_to(runner_temp)
    output.mkdir()
    project = Path(__file__).resolve().parents[3]
    updater_source = project / 'apps/airplay/source/overlay/app_updater.mm'
    harness = Path(__file__).with_name('UpdaterCheck.mm')
    info_path = bundle / 'Contents/Info.plist'
    info = plistlib.loads(info_path.read_bytes())
    require(info.get('CFBundleIdentifier') == 'local.chevy.airplay' and
            info.get('SUFeedURL') == FEED and info.get('SURequireSignedFeed') is True and
            info.get('SUVerifyUpdateBeforeExtraction') is True,
            'The input is not the configured AirPlay release bundle.')
    original_hashes = {name: digest(bundle / name) for name in (
        'Contents/Info.plist', 'Contents/MacOS/' + info['CFBundleExecutable'])}
    result = {'schema': 1, 'status': 'FAIL', 'production_source_sha256': digest(updater_source),
              'harness_sha256': digest(harness), 'feed_url': FEED,
              'source_bundle_version': info['CFBundleShortVersionString'],
              'source_bundle_build': info['CFBundleVersion'],
              'real_sparkle_version': '2.9.6', 'installation_requested': False,
              'production_bundle_modified': False, 'phases': []}
    identifier = 'local.chevy.airplay.updatercheck.' + uuid.uuid4().hex
    try:
        result['macos'] = subprocess.check_output(['/usr/bin/sw_vers', '-productVersion'], text=True).strip()
        result['architecture'] = subprocess.check_output(['/usr/bin/uname', '-m'], text=True).strip()
        require(result['architecture'] == 'x86_64', 'Use the reviewed Intel runner.')
        with tempfile.TemporaryDirectory(prefix='airplay-updater-check-', dir=runner_temp) as temporary:
            fixture = Path(temporary) / 'AirPlayUpdaterCheck.app'
            executable_dir = fixture / 'Contents/MacOS'
            frameworks = fixture / 'Contents/Frameworks'
            executable_dir.mkdir(parents=True)
            frameworks.mkdir()
            run(['/usr/bin/ditto', bundle / 'Contents/Frameworks/Sparkle.framework',
                 frameworks / 'Sparkle.framework'], output / 'fixture-build.log')
            sparkle_info = plistlib.loads((frameworks / 'Sparkle.framework/Resources/Info.plist').read_bytes())
            require(sparkle_info.get('CFBundleShortVersionString') == '2.9.6', 'Unexpected Sparkle SDK.')
            fixture_info = dict(info)
            fixture_info.update(CFBundleIdentifier=identifier, CFBundleExecutable='UpdaterCheck',
                                CFBundleName='AirPlay Updater Check', CFBundleDisplayName='AirPlay Updater Check',
                                CFBundleVersion='1', CFBundleShortVersionString='0.0.1',
                                NSPrincipalClass='NSApplication', AirPlayUpdaterPolicyCheck=True)
            for key in ('CFBundleIconFile', 'CFBundleIconName'):
                fixture_info.pop(key, None)
            (fixture / 'Contents/Info.plist').write_bytes(plistlib.dumps(fixture_info))
            gst = Path('/Library/Frameworks/GStreamer.framework/Versions/1.0')
            pkg_environment = os.environ.copy()
            pkg_environment['PKG_CONFIG_PATH'] = str(gst / 'lib/pkgconfig')
            pkg_environment['PKG_CONFIG_LIBDIR'] = str(gst / 'lib/pkgconfig')
            flags = shlex.split(subprocess.check_output([str(gst / 'bin/pkg-config'), '--cflags',
                                                       'gstreamer-1.0'], env=pkg_environment, text=True))
            require(not any('Cellar' in flag or '/opt/homebrew' in flag for flag in flags),
                    'The harness must use the selected official GStreamer headers.')
            command = ['/usr/bin/xcrun', 'clang++', '-std=c++11', '-fobjc-arc', '-fblocks',
                       '-arch', 'x86_64', '-mmacosx-version-min=11.0', '-Werror=objc-method-access',
                       '-DAIRPLAY_UPDATER_IMPLEMENTATION="' + str(updater_source) + '"',
                       '-F', frameworks, '-framework', 'Cocoa', '-framework', 'Sparkle',
                       '-Wl,-rpath,@executable_path/../Frameworks', *flags, harness,
                       '-o', executable_dir / 'UpdaterCheck']
            run(command, output / 'compile.log')
            run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', fixture], output / 'fixture-build.log')
            run(['/usr/bin/codesign', '--verify', '--deep', '--strict', fixture], output / 'fixture-build.log')
            for phase in ('default-opt-in', 'restored-opt-in', 'restored-off'):
                environment = os.environ.copy()
                report = output / (phase + '.json')
                environment['AIRPLAY_UPDATER_CHECK_RESULT'] = str(report)
                run([executable_dir / 'UpdaterCheck', phase], output / (phase + '.log'),
                    env=environment, timeout=95)
                phase_result = json.loads(report.read_text())
                require(phase_result.get('status') == 'PASS' and
                        phase_result.get('installation_requested') is False,
                        'A required native updater phase did not pass.')
                result['phases'].append(phase_result)
            require(original_hashes == {name: digest(bundle / name) for name in original_hashes},
                    'The production bundle was modified by the test.')
            result['status'] = 'PASS'
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        result['error'] = str(error)
        raise
    finally:
        # Delete only the UUID-named fixture preferences, never AirPlay's domain.
        subprocess.run(['/usr/bin/defaults', 'delete', identifier], stdout=subprocess.DEVNULL,
                       stderr=subprocess.DEVNULL, check=False)
        (output / 'updater-check.json').write_text(json.dumps(result, indent=2) + '\n')
    print('PASS: real production updater, saved opt-in/out, signed scheduled feed, gentle UI, and manual checks.')


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        raise SystemExit('ERROR: ' + str(error))
