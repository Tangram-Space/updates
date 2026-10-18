#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Fetch only the pinned public SDK; never generate or access a signing key.
set -euo pipefail
umask 077
ap_fail() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 1 ] || ap_fail 'Usage: fetch-sparkle.sh NEW_ARCHIVE_PATH'
[ "${CI:-}" = true ] && [ "${GITHUB_ACTIONS:-}" = true ] &&
  [ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] || ap_fail 'A hosted Actions runner is required.'
[ "${RUNNER_OS:-}" = macOS ] && [ "${RUNNER_ARCH:-}" = X64 ] &&
  [ "$(/usr/bin/uname -s)" = Darwin ] && [ "$(/usr/bin/uname -m)" = x86_64 ] ||
  ap_fail 'An Intel macOS runner is required.'
[ "${GITHUB_SERVER_URL:-}" = https://github.com ] &&
  [ "${GITHUB_REPOSITORY:-}" = Tangram-Space/updates ] &&
  [ "${GITHUB_REF:-}" = refs/heads/main ] &&
  [ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ] &&
  [ "${AIRPLAY_PUBLIC_CI_ENABLED:-}" = true ] || ap_fail 'This reviewed public job is not enabled.'
AP_OUTPUT="$1"
AP_PYTHON="$(/usr/bin/xcrun --find python3)"
"$AP_PYTHON" - "$AP_OUTPUT" <<'PY'
import json
import os
from pathlib import Path
import sys
with Path(os.environ['GITHUB_EVENT_PATH']).open(encoding='utf-8') as stream:
    repo = json.load(stream).get('repository', {})
if (repo.get('private') is not False or repo.get('visibility') != 'public'
        or repo.get('full_name') != 'Tangram-Space/updates'):
    raise SystemExit('The dispatch repository must be the reviewed public updates repository.')
root = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
output = Path(sys.argv[1])
if not output.is_absolute() or output.is_symlink() or output.exists():
    raise SystemExit('Use a new absolute archive path inside RUNNER_TEMP.')
output.parent.resolve(strict=True).relative_to(root)
if output.name != 'Sparkle-2.9.6.tar.xz':
    raise SystemExit('Unexpected Sparkle archive basename.')
part = Path(str(output) + '.part')
if part.exists() or part.is_symlink():
    raise SystemExit('A partial archive already exists; use a new job directory.')
PY
AP_EXPECTED=52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192
trap '/bin/rm -f "$AP_OUTPUT.part"' EXIT
/usr/bin/curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
  --connect-timeout 20 --max-time 300 --retry 2 --retry-delay 2 \
  --output "$AP_OUTPUT.part" \
  https://github.com/sparkle-project/Sparkle/releases/download/2.9.6/Sparkle-2.9.6.tar.xz
[ "$(/usr/bin/shasum -a 256 "$AP_OUTPUT.part" | /usr/bin/awk '{print $1}')" = "$AP_EXPECTED" ] ||
  ap_fail 'The Sparkle 2.9.6 archive does not match its reviewed SHA256.'
/bin/mv "$AP_OUTPUT.part" "$AP_OUTPUT"
printf 'Verified Sparkle 2.9.6 SHA256 %s\n' "$AP_EXPECTED"
