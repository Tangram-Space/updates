#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Embed this project's verified source and resources in a macOS Bash bootstrap."""
from pathlib import Path
import argparse
import base64
import hashlib
import json
import os
import plistlib
import re
import subprocess
import sys

PROJECT = Path(__file__).resolve().parents[1]
LOCALES = ['en', 'en-US', 'en-GB', 'en-CA', 'en-AU',
           'es', 'es-ES', 'es-MX', 'es-AR', 'es-419']

def sha(data):
    return hashlib.sha256(data).hexdigest()

def manifest(root, path):
    result = []
    for line in path.read_text().splitlines():
        digest, relative = line.split('  ', 1)
        assert re.fullmatch(r'[0-9a-f]{64}', digest)
        assert not relative.startswith('/') and '..' not in Path(relative).parts
        source = root / relative
        assert source.is_file() and not source.is_symlink(), relative
        data = source.read_bytes()
        assert sha(data) == digest, 'Manifest mismatch: ' + relative
        result.append((relative, data, digest))
    return result

def quoted_payload(target, data, delimiter):
    text = data.decode('utf-8')
    assert text.endswith('\n') and '\r' not in text
    assert f'\n{delimiter}\n' not in text
    return (f'/bin/cat > "{target}" <<\'{delimiter}\'\n{text}{delimiter}\n'
            '[ "$?" -eq 0 ] || ux_fail "No se pudo escribir un archivo del paquete."')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--update-config', type=Path)
    parser.add_argument('--icon-file', type=Path)
    parser.add_argument('--build-only', action='store_true',
                        help='Prepare a verified bundle and unsigned update archive without installing; requires an update configuration.')
    args = parser.parse_args()
    values = {}
    for line in (PROJECT / 'version.env').read_text().splitlines():
        if line and not line.startswith('#'):
            key, value = line.split('=', 1)
            values[key] = value
    sources = manifest(PROJECT / 'overlay', PROJECT / 'manifests/overlay.sha256')
    resources = manifest(PROJECT / 'resources', PROJECT / 'manifests/resources.sha256')
    licenses = manifest(PROJECT, PROJECT / 'manifests/licenses.sha256')
    plist = plistlib.loads((PROJECT / 'resources/Info.plist.in').read_bytes()
                          .replace(b'@AIRPLAY_VERSION@', values['AIRPLAY_VERSION'].encode())
                          .replace(b'@AIRPLAY_BUILD@', values['AIRPLAY_BUILD'].encode()))
    assert plist['CFBundleIdentifier'] == values['AIRPLAY_BUNDLE_ID']
    assert plist['CFBundleLocalizations'] == LOCALES
    config_path = args.update_config or PROJECT / 'updates/UpdateConfig.plist'
    state = 'NOT_CONFIGURED'
    if config_path.exists():
        subprocess.run([sys.executable, str(PROJECT / 'scripts/update_release.py'),
                        'validate-config', '--config', str(config_path)], check=True)
        update_config = plistlib.loads(config_path.read_bytes())
        plist['SUFeedURL'] = update_config['SUFeedURL']
        plist['SUPublicEDKey'] = update_config['SUPublicEDKey']
        state = 'CONFIGURED_MANUAL'
    elif args.update_config:
        raise FileNotFoundError(config_path)
    if args.build_only and state != 'CONFIGURED_MANUAL':
        parser.error('--build-only requires a valid updates/UpdateConfig.plist or --update-config file; no bootstrap was written.')
    plist['CFBundleIconFile'] = 'AirPlay.icns'
    # The default is an original vector icon rendered by AppKit on the target
    # Mac. Every normal installation therefore includes a real bundle icon.
    icon_parts = ['/bin/mkdir -p "$UX_WORK/icon-sources.noindex" || ux_fail "No se pudo preparar el icono."']
    for index, name in enumerate(('render-icon.m', 'make-icon.sh'), 1):
        data = (PROJECT / 'scripts' / name).read_bytes()
        target = f'$UX_WORK/icon-sources.noindex/{name}'
        icon_parts.append(quoted_payload(target, data, f'AIRPLAY_ORIGINAL_ICON_SOURCE_{index}_END'))
        icon_parts.append(f'ux_check_file "{target}" "{sha(data)}" "generador del icono {name}"')
    icon_parts.append('ux_run /bin/bash "$UX_WORK/icon-sources.noindex/make-icon.sh" '
                      '"$UX_APP/Contents/Resources/AirPlay.icns" "$UX_WORK/icon-render.noindex"')
    icon_payload = '\n\n'.join(icon_parts)
    if args.icon_file:
        icon = args.icon_file.read_bytes()
        assert icon[:4] == b'icns' and len(icon) >= 8, 'Expected an existing .icns file'
        encoded = base64.encodebytes(icon).decode('ascii')
        icon_payload = ("/usr/bin/base64 -D > \"$UX_APP/Contents/Resources/AirPlay.icns\" <<'AIRPLAY_PROVIDED_ICON'\n"
                        + encoded + "AIRPLAY_PROVIDED_ICON\n"
                        + '[ "$?" -eq 0 ] || ux_fail "No se pudo escribir el icono proporcionado."\n'
                        + f'ux_check_file "$UX_APP/Contents/Resources/AirPlay.icns" "{sha(icon)}" "icono proporcionado"')
    cleanup_parts = ['/bin/mkdir -p "$UX_WORK/postinstall.noindex" || ux_fail "No se pudo preparar el mantenimiento."']
    for index, name in enumerate(('cleanup_tools.py', 'cleanup-tools.sh', 'postinstall-cleanup.sh'), 1):
        data = (PROJECT / 'scripts' / 'repair' / name).read_bytes()
        target = f'$UX_WORK/postinstall.noindex/{name}'
        cleanup_parts.append(quoted_payload(target, data, f'AIRPLAY_POSTINSTALL_SOURCE_{index}_END'))
        cleanup_parts.append(f'ux_check_file "{target}" "{sha(data)}" "mantenimiento {name}"')
    source_payloads = []
    source_checks = []
    for index, (relative, data, digest) in enumerate(sources, 1):
        assert re.fullmatch(r'[A-Za-z0-9_./-]+', relative)
        source_payloads.append(quoted_payload(f'$UX_SRC/{relative}', data, f'AIRPLAY_APP_SOURCE_{index}_END'))
        source_checks.append(f'  ux_check_file "$UX_SRC/{relative}" "{digest}" "fuente app {relative}"')
    resource_payloads, resource_checks, resource_lints, localized = [], [], [], []
    receiver = None
    for index, (relative, data, digest) in enumerate(resources, 1):
        if relative == 'receiver.conf':
            receiver = data
            continue
        assert relative in {f'{locale}.lproj/Localizable.strings' for locale in LOCALES}, relative
        parent = Path(relative).parent.as_posix()
        target = f'$UX_APP/Contents/Resources/{relative}'
        resource_payloads.append(f'/bin/mkdir -p "$UX_APP/Contents/Resources/{parent}" || ux_fail "No se pudo crear la carpeta de idioma."\n'
                                 + quoted_payload(target, data, f'AIRPLAY_APP_RESOURCE_{index}_END'))
        resource_checks.append(f'  ux_check_file "$1/Contents/Resources/{relative}" "{digest}" "localizacion {relative}"')
        resource_lints.append(f'ux_run /usr/bin/plutil -lint "{target}"')
        localized.append(f'{digest}  {relative}')
    assert receiver and len(localized) == 10
    license_payloads = ['/bin/mkdir -p "$UX_APP/Contents/Resources/Licenses" || ux_fail "No se pudo crear la carpeta de licencias."']
    for index, (relative, data, digest) in enumerate(licenses, 1):
        name = Path(relative).name
        assert re.fullmatch(r'[A-Za-z0-9_.-]+', name)
        target = f'$UX_APP/Contents/Resources/Licenses/{name}'
        license_payloads.append(quoted_payload(target, data, f'AIRPLAY_LICENSE_{index}_END'))
        license_payloads.append(f'ux_check_file "{target}" "{digest}" "licencia {name}"')
    info_plist = plistlib.dumps(plist, fmt=plistlib.FMT_XML, sort_keys=False)
    replacements = {
        '@@FINAL_CHECKS@@': '\n'.join(source_checks),
        '@@RESOURCE_CHECKS@@': '\n'.join(resource_checks),
        '@@UPSTREAM_MANIFEST@@': (PROJECT / 'manifests/upstream.sha256').read_text().rstrip('\n'),
        '@@SOURCE_PAYLOADS@@': '\n\n'.join(source_payloads),
        '@@SOURCE_MANIFEST@@': '\n'.join(f'{digest}  {relative}' for relative, _, digest in sources),
        '@@RECEIVER_CONFIGURATION@@': receiver.decode('utf-8').rstrip('\n'),
        '@@RESOURCE_PAYLOADS@@': '\n\n'.join(resource_payloads),
        '@@RESOURCE_LINTS@@': '\n'.join(resource_lints),
        '@@RESOURCE_MANIFEST@@': '\n'.join(localized),
        '@@INFO_PLIST@@': info_plist.decode().rstrip('\n'),
        '@@INFO_PLIST_SHA@@': sha(info_plist),
        '@@DEFAULT_MODE@@': 'build-only' if args.build_only else 'install',
        '@@UPDATE_CHANNEL_STATE@@': state,
        '@@OPTIONAL_ICON@@': icon_payload,
        '@@POSTINSTALL_PAYLOADS@@': '\n\n'.join(cleanup_parts),
        '@@LICENSE_PAYLOADS@@': '\n\n'.join(license_payloads),
    }
    result = (PROJECT / 'scripts/bootstrap.command.in').read_text()
    for token, content in replacements.items():
        assert token in result, token
        result = result.replace(token, content)
    assert not re.search(r'@@[A-Z_]+@@', result), 'Unresolved template token'
    for key, value in [('UX_CONF_SHA', sha(receiver)),
                       ('UX_AUDIO_SHA', sha((PROJECT/'overlay/lib/raop_rtp.c').read_bytes())),
                       ('UX_COMMIT', values['AIRPLAY_UPSTREAM_COMMIT'])]:
        assert f'{key}="{value}"' in result, key
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_bytes(result.encode('utf-8'))
    args.output.chmod(0o755)
    print(json.dumps({'file': str(args.output), 'sha256': sha(args.output.read_bytes()),
                      'bytes': args.output.stat().st_size, 'version': values['AIRPLAY_VERSION'],
                      'build': values['AIRPLAY_BUILD'], 'updates': state,
                      'mode': 'build-only' if args.build_only else 'install'}, indent=2))

if __name__ == '__main__':
    main()
