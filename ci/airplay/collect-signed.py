#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Collect the exact outputs of a SUCCESSFUL sign-release step, not its temp tree."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil

FEED = 'https://raw.githubusercontent.com/Tangram-Space/updates/main/feeds/airplay/stable/appcast.xml'


def checked_file(path, parent):
    if path.is_symlink() or not path.is_file():
        raise ValueError('Unexpected artifact file: ' + path.name)
    path.resolve(strict=True).relative_to(parent)
    return path


def digest(path):
    result = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            result.update(chunk)
    return result.hexdigest()


def collect():
    if os.environ.get('AIRPLAY_CI_SIGN_OUTCOME') != 'success':
        raise ValueError('Signed outputs may be collected only after the signer succeeded.')
    temporary = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
    source = Path(os.environ['AIRPLAY_CI_SIGNED_OUTPUT'])
    if source.is_symlink() or not source.is_dir():
        raise ValueError('Unexpected signed-output directory.')
    source = source.resolve(strict=True)
    source.relative_to(temporary)
    artifacts = Path(os.environ['AIRPLAY_CI_ARTIFACT_DIR']).resolve(strict=True)
    artifacts.relative_to(temporary)
    preparation_path = checked_file(Path(os.environ['AIRPLAY_PREPARATION_JSON']), temporary)
    release_path = checked_file(source / 'release.json', source)
    if preparation_path.stat().st_size > 64 * 1024 or release_path.stat().st_size > 64 * 1024:
        raise ValueError('An artifact report is unexpectedly large.')
    preparation = json.loads(preparation_path.read_text(encoding='utf-8'))
    release = json.loads(release_path.read_text(encoding='utf-8'))
    version, build = preparation.get('version'), preparation.get('build')
    if (not isinstance(version, str) or not re.fullmatch(r'[0-9]+(?:\.[0-9]+){1,2}', version)
            or not isinstance(build, str) or not re.fullmatch(r'[1-9][0-9]*', build)):
        raise ValueError('Unexpected release version.')
    name = 'AirPlay-' + version + '-' + build + '.zip'
    prefix = ('https://github.com/Tangram-Space/updates/releases/download/airplay-v'
              + version + '-b' + build + '/')
    expected = {'bundle_id': 'local.chevy.airplay', 'version': version, 'build': build,
                'feed_url': FEED, 'download_url': prefix + name, 'archive': name,
                'sparkle_version': '2.9.6'}
    if any(release.get(key) != value for key, value in expected.items()) or release.get('published') is not False:
        raise ValueError('Signed release metadata differs from the reviewed channel/build.')
    if {path.name for path in source.iterdir()} != {name, 'appcast.xml', 'release.json'}:
        raise ValueError('Unexpected file in the signed-output directory.')
    archive = checked_file(source / name, source)
    appcast = checked_file(source / 'appcast.xml', source)
    if (digest(archive) != release.get('archive_sha256')
            or archive.stat().st_size != release.get('archive_bytes')
            or digest(appcast) != release.get('appcast_sha256')):
        raise ValueError('Signed output bytes no longer match the successful signer report.')
    output = artifacts / 'release'
    output.mkdir()  # Never merge or overwrite a previous release collection.
    for path in (archive, appcast, release_path):
        shutil.copyfile(path, output / path.name)
    result = {'schema': 1, 'repository': os.environ['GITHUB_REPOSITORY'],
              'source_commit': os.environ['GITHUB_SHA'], 'archive_signed_ed25519': True,
              'appcast_signature_verified': True, 'published': False,
              'big_sur_runtime_tested': False, 'release_directory': 'release',
              'release_tag': 'airplay-v' + version + '-b' + build}
    with (artifacts / 'signing-result.json').open('x', encoding='utf-8') as stream:
        json.dump(result, stream, indent=2)
        stream.write('\n')
    with Path(os.environ['GITHUB_STEP_SUMMARY']).open('a', encoding='utf-8') as stream:
        stream.write('## Signed AirPlay preparation\n\n'
                     'The official Sparkle tools verified the archive and appcast signatures. '
                     'The final ZIP, appcast and release report are in `release/`. '
                     'No release or feed was published. Big Sur execution still needs its native validation.\n')


if __name__ == '__main__':
    try:
        collect()
    except (ValueError, OSError, KeyError) as error:
        raise SystemExit('ERROR: ' + str(error))
