#!/bin/bash
# Produces reviewable, signed release files locally. Does not upload anything.
set -euo pipefail
AP_UPDATES_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
if [ "$(/usr/bin/uname -s)" != Darwin ]; then
  printf '%s\n' 'Run this operation on the signing Mac with Xcode tools installed.' >&2
  exit 1
fi
AP_UPDATES_PYTHON="$(/usr/bin/xcrun --find python3)"
exec "$AP_UPDATES_PYTHON" "$AP_UPDATES_SCRIPT_DIR/update_release.py" release "$@"
