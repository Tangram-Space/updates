#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Check source manifests, preserved playback, generated payloads and shell syntax."""
from pathlib import Path
import hashlib
import json
import plistlib
import re
import subprocess
import sys
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
def digest(data):
    return hashlib.sha256(data).hexdigest()

def manifest(name, root):
    entries = {}
    for line in (PROJECT / 'manifests' / name).read_text().splitlines():
        expected, relative = line.split('  ', 1)
        content = (root / relative).read_bytes()
        assert digest(content) == expected, relative
        entries[relative] = content
    return entries

def payloads(script, variable, kind):
    pattern = (r'/bin/cat > "\$' + re.escape(variable) +
               r'/([^"\n]+)" <<\'(AIRPLAY_APP_' + kind +
               r'_\d+_END)\'\n(.*?)\n\2\n')
    return {m.group(1): (m.group(3) + '\n').encode() for m in re.finditer(pattern, script, re.S)}

sources = manifest('overlay.sha256', PROJECT / 'overlay')
resources = manifest('resources.sha256', PROJECT / 'resources')
manifest('licenses.sha256', PROJECT)
baseline = json.loads((PROJECT / 'manifests/baselines/1.2.json').read_text())
for item in baseline['sources']:
    if item['path'] not in {'CMakeLists.txt', 'app_controller.h', 'app_controller.mm'}:
        assert digest(sources[item['path']]) == item['sha256'], item['path']
assert digest(sources['lib/raop_rtp.c']) == baseline['rtp_sha256']
assert digest(resources['receiver.conf']) == baseline['receiver_configuration_sha256']
keys = None
for name, content in resources.items():
    if not name.endswith('.strings'):
        continue
    current = re.findall(r'^"([^"\n]+)"\s*=', content.decode(), re.M)
    assert len(current) == len(set(current)) == 62, name
    if keys is None:
        keys = set(current)
    assert set(current) == keys, name
with tempfile.TemporaryDirectory(prefix='airplay-source-check-') as temporary:
    output = Path(temporary) / 'Instalar_AirPlay.command'
    command = [sys.executable, str(PROJECT / 'scripts/package-bootstrap.py'), '--output', str(output)]
    subprocess.run(command, check=True, capture_output=True)
    first = output.read_bytes()
    subprocess.run(command, check=True, capture_output=True)
    assert output.read_bytes() == first, 'Bootstrap generation is not deterministic'
    subprocess.run(['/bin/bash', '-n', str(output)], check=True)
    script = first.decode()
    assert payloads(script, 'UX_SRC', 'SOURCE') == sources
    localized = {name: content for name, content in resources.items() if name.endswith('.strings')}
    assert payloads(script, 'UX_APP/Contents/Resources', 'RESOURCE') == localized
    receiver = script.split("<<'AIRPLAY_RECEIVER_CONFIGURATION'\n", 1)[1].split('\nAIRPLAY_RECEIVER_CONFIGURATION\n', 1)[0].encode() + b'\n'
    assert receiver == resources['receiver.conf']
    plist = plistlib.loads(script.split("<<'AIRPLAY_INFO_PLIST'\n", 1)[1].split('\nAIRPLAY_INFO_PLIST\n', 1)[0].encode())
    assert plist['CFBundleIdentifier'] == 'local.chevy.airplay'
    assert plist['CFBundleShortVersionString'] == '1.3.3' and plist['CFBundleVersion'] == '7'
    assert plist['CFBundleIconFile'] == 'AirPlay.icns'
    assert 'AIRPLAY_ORIGINAL_ICON_SOURCE_1_END' in script
    assert 'AIRPLAY_ORIGINAL_ICON_SOURCE_2_END' in script
    assert '"$UX_APP/Contents/Resources/AirPlay.icns" "$UX_WORK/icon-render.noindex"' in script
    assert plist['LSUIElement'] is True and plist['LSBackgroundOnly'] is False
    assert plist['SURequireSignedFeed'] is True and plist['SUVerifyUpdateBeforeExtraction'] is True
    assert plist['SUEnableAutomaticChecks'] is False and plist['SUAutomaticallyUpdate'] is False
    assert plist['SUAllowsAutomaticUpdates'] is False
    if not (PROJECT / 'updates/UpdateConfig.plist').exists():
        assert 'SUFeedURL' not in plist and 'SUPublicEDKey' not in plist
    assert script.index('ux_check_file "$UX_SPARKLE_ARCHIVE"') < script.index('ux_run /usr/bin/tar -xJf "$UX_SPARKLE_ARCHIVE"')
    assert script.index('"$UX_STAGED_APP/Contents/MacOS/uxplay" --airplay-check') < script.index('"$UX_STAGED_APP/Contents/MacOS/uxplay" --airplay-ui-check') < script.index('UX_PHASE="instalacion"')
    for line in script.splitlines():
        if '/usr/bin/codesign' in line and '--sign' in line:
            assert '--deep' not in line
    assert '@@' not in script
    generated_digest = digest(first)
for path in (PROJECT / 'scripts').glob('*.sh'):
    subprocess.run(['/bin/bash', '-n', str(path)], check=True)
print(json.dumps({'source_files': len(sources), 'localized_resources': 10,
                  'keys_per_locale': len(keys), 'source_preservation': 'PASS',
                  'payload_and_regeneration': 'PASS', 'bash_syntax': 'PASS',
                  'portable_bootstrap_sha256': generated_digest,
                  'macos_compile_or_runtime_performed': False}, indent=2))
