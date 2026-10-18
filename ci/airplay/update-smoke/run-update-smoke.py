#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Hosted-Mac-only self-update: synthetic A -> real, published AirPlay B.

The observer never opens B. Only Sparkle may replace A and relaunch that path.
The frozen public hashes supplied by the manual dispatch identify the release.
No private key, Keychain operation, permission change or /Applications mutation.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import platform
import plistlib
import posixpath
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET
import zipfile

FEED = 'https://raw.githubusercontent.com/Tangram-Space/updates/main/feeds/airplay/stable/appcast.xml'
PUBLIC_KEY = 'i8eQAeVM6gqQ7M7YeAlnGqSZQ0Wn8321shPPPdafH7A='
BUNDLE_ID = 'local.chevy.airplay'
SPARKLE_NS = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()


def child_environment():
    # Preserve the real ephemeral account. Do not change HOME or pass CI tokens.
    keep = ('HOME', 'USER', 'LOGNAME', 'TMPDIR', 'LANG', 'LC_ALL', '__CF_USER_TEXT_ENCODING')
    env = {key: os.environ[key] for key in keep if key in os.environ}
    env['PATH'] = '/usr/bin:/bin:/usr/sbin:/sbin'
    return env


def run(command, log, timeout=120):
    with log.open('ab') as stream:
        result = subprocess.run([str(value) for value in command], stdout=stream,
                                stderr=subprocess.STDOUT, env=child_environment(), timeout=timeout)
    require(result.returncode == 0, 'Command failed; inspect ' + log.name)


def read_info(bundle):
    with (bundle / 'Contents/Info.plist').open('rb') as stream:
        return plistlib.load(stream)


def inventory(root):
    result = {}
    for path in sorted(root.rglob('*')):
        name = path.relative_to(root).as_posix()
        mode = path.lstat().st_mode
        if stat.S_ISLNK(mode):
            result[name] = ['symlink', os.readlink(str(path))]
        elif stat.S_ISREG(mode):
            result[name] = ['file', digest(path)]
        elif not stat.S_ISDIR(mode):
            raise RuntimeError('Unexpected special file inside the application.')
    return result


def processes_at(executable):
    # With stdout in a pipe, macOS ps supplies the full executable path in comm.
    result = subprocess.run(['/bin/ps', '-ww', '-axo', 'pid=,lstart=,comm='], check=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            text=True, env=child_environment(), timeout=10)
    found = []
    for line in result.stdout.splitlines():
        fields = line.strip().split(None, 6)
        if len(fields) == 7 and fields[0].isdigit() and fields[6] == str(executable):
            found.append({'pid': int(fields[0]), 'birth': ' '.join(fields[1:6]),
                          'executable': fields[6]})
    return found


def still_same(identity):
    return identity in processes_at(Path(identity['executable']))


def stop_owned(identity, cleanup):
    if not still_same(identity):
        return
    try:
        os.kill(identity['pid'], signal.SIGTERM)
    except ProcessLookupError:
        return
    cleanup.append({'signal': 'TERM', **identity})
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        if not still_same(identity):
            return
        time.sleep(0.2)
    if still_same(identity):
        try:
            os.kill(identity['pid'], signal.SIGKILL)
        except ProcessLookupError:
            return
        cleanup.append({'signal': 'KILL', **identity})


def events_from(path):
    events = []
    if path.exists():
        require(path.stat().st_size < 2 * 1024 * 1024, 'Unexpectedly large driver log.')
        for line in path.read_text(encoding='utf-8', errors='replace').splitlines():
            try:
                event = json.loads(line)
            except ValueError:
                continue
            if isinstance(event, dict) and isinstance(event.get('event'), str):
                events.append(event)
    return events


def validate_archive(path):
    with zipfile.ZipFile(path) as archive:
        entries = archive.infolist()
        require(sum(item.file_size for item in entries) < 256 * 1024 * 1024,
                'The release archive exceeds the test size limit.')
        for item in entries:
            parts = PurePosixPath(item.filename).parts
            require(parts and not item.filename.startswith('/') and '..' not in parts
                    and '\\' not in item.filename and '\x00' not in item.filename,
                    'Unsafe archive entry.')
            require(parts[0] in ('AirPlay.app', '__MACOSX'), 'Unexpected archive top-level entry.')
            if stat.S_ISLNK(item.external_attr >> 16):
                target = archive.read(item).decode('utf-8')
                resolved = posixpath.normpath(posixpath.join(posixpath.dirname(item.filename), target))
                require(not target.startswith('/') and resolved.startswith('AirPlay.app/'),
                        'An archive symlink leaves the application.')


def guard(output):
    expected = {'CI': 'true', 'GITHUB_ACTIONS': 'true', 'RUNNER_ENVIRONMENT': 'github-hosted',
                'RUNNER_OS': 'macOS', 'RUNNER_ARCH': 'X64', 'GITHUB_SERVER_URL': 'https://github.com',
                'GITHUB_REPOSITORY': 'Tangram-Space/updates', 'GITHUB_REF': 'refs/heads/main',
                'GITHUB_EVENT_NAME': 'workflow_dispatch', 'AIRPLAY_PUBLIC_CI_ENABLED': 'true'}
    require(all(os.environ.get(key) == value for key, value in expected.items()),
            'Run only in the explicitly enabled, manual public hosted-Mac workflow.')
    require(platform.system() == 'Darwin' and platform.machine() == 'x86_64' and os.geteuid() != 0,
            'An unprivileged Intel macOS runner is required.')
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text(encoding='utf-8'))
    repository = event.get('repository', {})
    require(repository.get('private') is False and repository.get('visibility') == 'public'
            and repository.get('full_name') == 'Tangram-Space/updates', 'The repository is not public.')
    temporary = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    require(not output.is_symlink() and output.is_dir(), 'The report directory must exist and not be a symlink.')
    output.resolve(strict=True).relative_to(temporary)
    require(output.resolve() != temporary and temporary != Path.home().resolve(), 'Unexpected report root.')
    for name in ('smoke-result.json', 'driver-A.jsonl', 'driver-A.stderr.log'):
        require(not (output / name).exists(), 'The report directory was already used.')
    return temporary


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--version', default='1.3.2')
    parser.add_argument('--build', default='6')
    parser.add_argument('--archive-sha256', required=True)
    parser.add_argument('--appcast-sha256', required=True)
    parser.add_argument('--archive-bytes', type=int, required=True)
    args = parser.parse_args()
    require(re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+', args.version), 'Invalid release version.')
    require(re.fullmatch(r'[1-9][0-9]*', args.build) and 2 <= int(args.build) <= 10**9, 'Invalid release build.')
    require(all(re.fullmatch(r'[0-9a-f]{64}', value) for value in
                (args.archive_sha256, args.appcast_sha256)), 'Supply the two reviewed final SHA256 values.')
    require(0 < args.archive_bytes < 100 * 1024 * 1024, 'Invalid release archive length.')
    output = args.output.absolute()
    temporary = guard(output)
    work = Path(tempfile.mkdtemp(prefix='airplay-self-update-', dir=str(temporary)))
    scripts = Path(__file__).resolve().parent
    archive_name = 'AirPlay-{}-{}.zip'.format(args.version, args.build)
    archive_url = 'https://github.com/Tangram-Space/updates/releases/download/airplay-v{}-b{}/{}'.format(
        args.version, args.build, archive_name)
    archive = work / archive_name
    feed = work / 'appcast.xml'
    fixture = work / 'fixture.noindex/AirPlay.app'
    executable = fixture / 'Contents/MacOS/uxplay'
    driver_log = output / 'driver-A.jsonl'
    source = None
    source_identity = None
    target_identity = None
    result = {'schema': 1, 'status': 'FAIL', 'synthetic_A': True, 'real_B': True,
              'repository': os.environ['GITHUB_REPOSITORY'], 'workflow_source_commit': os.environ['GITHUB_SHA'],
              'runner_macos': platform.mac_ver()[0], 'runner_arch': platform.machine(),
              'version': args.version, 'build': args.build, 'feed_url': FEED, 'download_url': archive_url,
              'archive_sha256': args.archive_sha256, 'appcast_sha256': args.appcast_sha256,
              'public_ed25519_key': PUBLIC_KEY, 'archive_bytes': args.archive_bytes,
              'public_verifier_source_sha256': digest(scripts / 'verify-release.swift'),
              'synthetic_driver_source_sha256': digest(scripts / 'SmokeDriver.m'),
              'checks': [], 'installed_to_user_applications': False, 'private_key_used': False,
              'permissions_changed': False, 'big_sur_runtime_tested': False,
              'actual_airplay_updater_ui_tested': False, 'streaming_tested': False, 'cleanup': []}
    started = time.monotonic()
    try:
        for url, destination, expected_hash in ((FEED, feed, args.appcast_sha256),
                                                (archive_url, archive, args.archive_sha256)):
            run(['/usr/bin/curl', '--disable', '--fail', '--location', '--proto', '=https',
                 '--proto-redir', '=https', '--tlsv1.2', '--connect-timeout', '20',
                 '--max-time', '180', '--retry', '2', '--output', destination, url],
                output / 'public-downloads.log', timeout=580)
            require(digest(destination) == expected_hash, 'Published bytes differ from the reviewed final release.')
        require(archive.stat().st_size == args.archive_bytes, 'Published archive size differs from the release.')
        require(feed.stat().st_size <= 2 * 1024 * 1024, 'The signed feed is unexpectedly large.')
        result['checks'].append('anonymous-downloads-and-frozen-sha256')
        items = ET.fromstring(feed.read_bytes()).findall('./channel/item')
        matches = [item for item in items if item.findtext(SPARKLE_NS + 'version') == args.build]
        require(len(matches) == 1, 'The published feed does not contain exactly one target build.')
        item = matches[0]
        enclosure = item.find('enclosure')
        require(enclosure is not None and enclosure.get('url') == archive_url
                and enclosure.get('length') == str(args.archive_bytes)
                and item.findtext(SPARKLE_NS + 'shortVersionString') == args.version,
                'The signed feed metadata differs from the requested release.')
        manifest = work / 'public-verification.json'
        manifest.write_text(json.dumps({'public_key': PUBLIC_KEY,
                                       'archive_signature': enclosure.get(SPARKLE_NS + 'edSignature')}), encoding='utf-8')
        verifier = work / 'verify-release'
        run(['/usr/bin/xcrun', 'swiftc', '-O', '-target', 'x86_64-apple-macosx11.0',
             scripts / 'verify-release.swift', '-o', verifier], output / 'compile-verifier.log')
        run([verifier, manifest, archive, feed], output / 'public-signatures.log')
        result['checks'].append('public-ed25519-archive-and-feed')
        validate_archive(archive)
        reference = work / 'reference.noindex'
        reference.mkdir()
        run(['/usr/bin/ditto', '-x', '-k', archive, reference], output / 'bundle-validation.log')
        target = reference / 'AirPlay.app'
        info = read_info(target)
        require(info.get('CFBundleIdentifier') == BUNDLE_ID and info.get('CFBundleVersion') == args.build
                and info.get('CFBundleShortVersionString') == args.version
                and info.get('CFBundleExecutable') == 'uxplay' and info.get('SUFeedURL') == FEED
                and info.get('SUPublicEDKey') == PUBLIC_KEY and info.get('SURequireSignedFeed') is True
                and info.get('SUVerifyUpdateBeforeExtraction') is True, 'The signed B bundle has unexpected identity or security settings.')
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', target], output / 'bundle-validation.log')
        framework = target / 'Contents/Frameworks/Sparkle.framework'
        require(framework.is_dir(), 'Sparkle framework is missing.')
        with (framework / 'Versions/B/Resources/Info.plist').open('rb') as stream:
            sparkle_info = plistlib.load(stream)
        require(sparkle_info.get('CFBundleShortVersionString') == '2.9.6', 'The signed B does not contain pinned Sparkle 2.9.6.')
        expected_inventory = inventory(target)
        expected_executable_sha = digest(target / 'Contents/MacOS/uxplay')
        result['target_executable_sha256'] = expected_executable_sha
        result['checks'].append('real-B-bundle-identity-signature-and-sparkle-version')

        # Test A is a disposable copy; original B and its signed ZIP stay untouched.
        fixture.parent.mkdir()
        run(['/usr/bin/ditto', target, fixture], output / 'fixture-build.log')
        run(['/usr/bin/xcrun', 'clang', '-fobjc-arc', '-fblocks', '-Werror=objc-method-access',
             '-Werror=protocol', '-arch', 'x86_64', '-mmacosx-version-min=11.0',
             scripts / 'SmokeDriver.m', '-framework', 'Cocoa', '-F', target / 'Contents/Frameworks',
             '-framework', 'Sparkle', '-Wl,-rpath,@executable_path/../Frameworks', '-o', executable],
            output / 'fixture-build.log')
        fixture_info = dict(info)
        fixture_info.update({'CFBundleVersion': str(int(args.build) - 1),
                             'CFBundleShortVersionString': args.version + '-smoke-A',
                             'CFBundleDisplayName': 'AirPlay — synthetic update test A',
                             'NSPrincipalClass': 'NSApplication', 'AirPlayUpdateSmokeFixture': True,
                             'AirPlaySmokeTargetBuild': args.build,
                             'AirPlaySmokeTargetArchiveURL': archive_url,
                             'AirPlaySmokeTargetArchiveBytes': args.archive_bytes})
        with (fixture / 'Contents/Info.plist').open('wb') as stream:
            plistlib.dump(fixture_info, stream)
        run(['/usr/bin/codesign', '--force', '--sign', '-', '--timestamp=none', fixture], output / 'fixture-build.log')
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', fixture], output / 'fixture-build.log')
        result['source_A_executable_sha256'] = digest(executable)
        require(result['source_A_executable_sha256'] != expected_executable_sha, 'A fixture was not built.')
        result['checks'].append('synthetic-A-main-bundle-built-and-signed')
        # These built-in checks do not receive AirPlay, write preferences or open windows.
        run([target / 'Contents/MacOS/uxplay', '--airplay-check'], output / 'real-B-preflight.log')
        run([target / 'Contents/MacOS/uxplay', '--airplay-ui-check'], output / 'real-B-preflight.log')
        result['checks'].append('real-B-runtime-and-offscreen-ui-preflight')

        with driver_log.open('xb') as stdout, (output / 'driver-A.stderr.log').open('xb') as stderr:
            source = subprocess.Popen([str(executable)], stdin=subprocess.DEVNULL,
                                      stdout=stdout, stderr=stderr, env=child_environment(), cwd=str(work))
        identity_deadline = time.monotonic() + 3
        while time.monotonic() < identity_deadline:
            candidates = [entry for entry in processes_at(executable) if entry['pid'] == source.pid]
            if candidates:
                source_identity = candidates[0]
                break
            if source.poll() is not None:
                break
            time.sleep(0.1)
        require(source_identity is not None, 'Could not establish the exact A process identity.')
        result['source_A_process'] = source_identity
        deadline = time.monotonic() + 300
        stable_since = None
        while time.monotonic() < deadline:
            events = events_from(driver_log)
            require(not any(event['event'] in ('failure', 'exception') for event in events),
                    'The A driver reported failure; inspect driver-A.jsonl.')
            exit_code = source.poll()
            if exit_code is not None:
                result['source_A_exit_code'] = exit_code
                require(exit_code == 0, 'The A process exited abnormally.')
                names = {event['event'] for event in events}
                require({'update_found', 'install_requested', 'application_will_terminate'} <= names,
                        'A exited without a complete signed-update and install request.')
                try:
                    current_info = read_info(fixture)
                except (OSError, ValueError):
                    current_info = {}
                if (current_info.get('CFBundleVersion') == args.build and executable.is_file()
                        and digest(executable) == expected_executable_sha):
                    targets = [entry for entry in processes_at(executable) if entry['pid'] != source.pid]
                    require(len(targets) <= 1, 'More than one process uses the isolated target path.')
                    if targets:
                        if target_identity != targets[0]:
                            target_identity, stable_since = targets[0], time.monotonic()
                        if time.monotonic() - stable_since >= 10:
                            break
                    else:
                        stable_since = None
            time.sleep(0.25)
        else:
            raise RuntimeError('Sparkle did not install and relaunch a stable B within five minutes.')

        require(inventory(fixture) == expected_inventory, 'Installed B differs from the exact signed release tree.')
        run(['/usr/bin/codesign', '--verify', '--deep', '--strict', fixture], output / 'installed-B-signature.log')
        require(target_identity is not None and still_same(target_identity), 'B exited before final verification.')
        app_log = Path.home() / 'Library/Logs/AirPlay/AirPlay.log'
        require(app_log.is_file() and not app_log.is_symlink() and app_log.stat().st_size < 4 * 1024 * 1024,
                'Real B did not produce its expected startup log.')
        startup_log = app_log.read_text(encoding='utf-8', errors='replace')
        require('AIRPLAY_APP launch ' in startup_log and 'bundle=' + str(fixture) in startup_log,
                'The startup log does not identify the Sparkle-installed B path.')
        shutil.copyfile(app_log, output / 'real-B-startup.log')
        result['checks'].extend(['signed-feed-selected-by-sparkle', 'sparkle-install-request-and-A-normal-termination',
                                 'installed-B-exact-file-tree-and-code-signature', 'B-relaunched-by-sparkle-new-pid',
                                 'real-B-startup-and-ten-seconds-alive'])
        result['target_B_process'] = target_identity
        result['observer_launched_B'] = False
        result['status'] = 'PASS'
    except Exception as error:
        result['error'] = str(error)
    finally:
        # Only the exact, newly created fixture path and birth-verified PID are eligible.
        try:
            for identity in (target_identity, source_identity):
                if identity is not None:
                    stop_owned(identity, result['cleanup'])
            if source is not None and source.poll() is not None:
                result['source_A_exit_code'] = source.returncode
        except Exception as error:
            result['cleanup_error'] = str(error)
            result['status'] = 'FAIL'
        result['elapsed_seconds'] = round(time.monotonic() - started, 2)
        try:
            result['driver_events'] = events_from(driver_log)
        except Exception as error:
            result['driver_log_error'] = str(error)
            result['status'] = 'FAIL'
        with (output / 'smoke-result.json').open('x', encoding='utf-8') as stream:
            json.dump(result, stream, indent=2, sort_keys=True)
            stream.write('\n')
    print(result['status'] + ': isolated Sparkle A -> real AirPlay B update smoke.')
    if result.get('error'):
        print(result['error'], file=sys.stderr)
    return 0 if result['status'] == 'PASS' else 1


if __name__ == '__main__':
    try:
        sys.exit(main())
    except Exception as error:
        print('ERROR: ' + str(error), file=sys.stderr)
        sys.exit(1)
