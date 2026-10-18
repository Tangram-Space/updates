#!/bin/bash
# Called by the repair after its app work; no sudo or shell configuration loaded.
set -euo pipefail
AP_CLEANUP_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
if [ "$(/usr/bin/uname -s)" != Darwin ]; then
  printf '%s\n' 'Run this relocation hook on the iMac.' >&2
  exit 1
fi
AP_CLEANUP_PYTHON="$(/usr/bin/xcrun --find python3)"
exec "$AP_CLEANUP_PYTHON" "$AP_CLEANUP_SCRIPT_DIR/cleanup_tools.py" "$@"
