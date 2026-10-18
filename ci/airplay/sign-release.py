#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Sign the verified build-only bundle; never install it or publish artifacts."""
import argparse
import json
from pathlib import Path
import re
import sys
from types import SimpleNamespace

from sparkle_signing import FEED_URL, main_guard, require


def local_file(path, parent):
    require(path.is_file() and not path.is_symlink(), 'An expected local release input is not a regular file.')
    path.resolve(strict=True).relative_to(parent.resolve(strict=True))
    return path


def prepare(core, signing, temporary):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--preparation-report', required=True, type=Path)
    parser.add_argument('--config', required=True)
    parser.add_argument('--sparkle-archive', required=True)
    parser.add_argument('--download-url-prefix', required=True)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--previous-appcast', type=Path)
    args = parser.parse_args()
    report_path = local_file(args.preparation_report.absolute(), temporary)
    require(report_path.name == 'preparacion.json' and report_path.parent.name == 'paquete.noindex'
            and report_path.stat().st_size <= 64 * 1024, 'Unexpected build preparation report.')
    build = report_path.parent.parent
    require(build.name.startswith('airplay-'), 'The report is outside the expected build directory.')
    report = json.loads(report_path.read_text(encoding='utf-8'))
    app = build / 'bundle.noindex/AirPlay.app'
    require(app.is_dir() and not app.is_symlink(), 'The prepared app is not a regular bundle directory.')
    expected = {'schema': 1, 'status': 'AWAITING_RELEASE_SIGNATURE_AND_PUBLICATION',
                'bundle': str(app), 'bundle_id': core.BUNDLE_ID, 'minimum_macos': '11.0',
                'bundle_code_signature': 'ad-hoc',
                'upstream_commit': 'df67c212a433cf6dda3676dd40c097900d24e645'}
    require(all(report.get(key) == value for key, value in expected.items()),
            'The preparation report does not match the reviewed build-only contract.')
    require(all(report.get(key) is False for key in
                ('archive_signed_ed25519', 'feed_access_verified', 'published', 'installed')),
            'The preparation report has an unexpected signing/publication state.')
    require(set(report.get('checks', [])) ==
            {'bundle-signature', 'airplay-check', 'airplay-ui-check', 'archive-roundtrip'},
            'The bundle did not pass every required preparation check.')
    name = report.get('archive', '')
    require(isinstance(name, str) and re.fullmatch(r'AirPlay-[0-9]+(?:\.[0-9]+){1,2}-[1-9][0-9]*\.zip', name),
            'Unexpected prepared archive filename.')
    require(name == 'AirPlay-{}-{}.zip'.format(report.get('version'), report.get('build')),
            'The prepared archive name differs from its reported version.')
    archive = local_file(report_path.parent / name, build)
    require(core.sha256(archive) == report.get('archive_sha256') and
            archive.stat().st_size == report.get('archive_bytes'),
            'The prepared ZIP no longer matches its verified report.')
    executable = local_file(app / 'Contents/MacOS/uxplay', build)
    require(core.sha256(executable) == report.get('executable_sha256'),
            'The prepared executable changed after its native checks.')
    config = core.read_config(args.config)
    require(config['SUFeedURL'] == FEED_URL, 'The configuration does not use the reviewed stable AirPlay feed.')
    require(report.get('feed_url') == config['SUFeedURL'] and
            report.get('public_ed25519_key') == config['SUPublicEDKey'],
            'The prepared bundle uses another update channel.')
    metadata = core.app_metadata(app, config)
    require(metadata['CFBundleShortVersionString'] == report['version'] and
            metadata['CFBundleVersion'] == report['build'],
            'The bundle version changed after its preparation checks.')
    prefix = core.public_url(args.download_url_prefix, prefix=True)
    expected_prefix = ('https://github.com/Tangram-Space/updates/releases/download/airplay-v'
                       + report['version'] + '-b' + report['build'] + '/')
    require(prefix == expected_prefix, 'The download prefix must identify this exact AirPlay release in Tangram-Space/updates.')
    output = args.output.absolute()
    output.parent.resolve(strict=True).relative_to(temporary)
    require(not output.exists() and not output.is_symlink(), 'Use a new runner-local signed-output directory.')
    previous = None
    if args.previous_appcast:
        previous = local_file(args.previous_appcast.absolute(), temporary)
        require(previous.stat().st_size <= 2 * 1024 * 1024, 'The previous appcast is unexpectedly large.')
    with core.official_tools(args.sparkle_archive) as tools:
        public = signing.derive_public_key(tools, core)
        require(public == config['SUPublicEDKey'],
                'The Actions signing secret does not match the public key embedded in the app.')
        # Verify the existing feed BEFORE the core parses it or compares builds.
        if previous:
            core.run([tools / 'sign_update', '--account', core.KEYCHAIN_ACCOUNT, '--verify', previous])
        core.keychain_public_key = lambda verified_tools: public
        core.make_release(SimpleNamespace(config=args.config, sparkle_archive=args.sparkle_archive,
                                         app=str(app), download_url_prefix=prefix, output=str(output),
                                         previous_appcast=str(previous) if previous else None))
    expected_names = {name, 'appcast.xml', 'release.json'}
    require({path.name for path in output.iterdir()} == expected_names,
            'Unexpected file in the signed release output.')
    print('ZIP and appcast signatures verified; publication remains a separate step.')


if __name__ == '__main__':
    sys.exit(main_guard(prepare))
