#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Build an isolated bundle; install by default, or prepare a release candidate.
. "$(dirname "$0")/common.sh"
AP_BUILD_ONLY=0
if [ "$#" -eq 1 ] && [ "$1" = --build-only ]; then
  AP_BUILD_ONLY=1
elif [ "$#" -ne 0 ]; then
  ap_fail "Usage: /bin/bash scripts/build-install.sh [--build-only]"
fi
ap_require_mac
AP_PYTHON="$(/usr/bin/xcrun --find python3 2>/dev/null)" || AP_PYTHON="$(command -v python3 2>/dev/null || :)"
[ -x "$AP_PYTHON" ] || ap_fail "Python 3 from Xcode is required to generate the bootstrap."
/bin/mkdir -p "$AP_PROJECT/.build.noindex" || ap_fail "Cannot create the local build directory."
AP_BOOTSTRAP_DIR="$(/usr/bin/mktemp -d "$AP_PROJECT/.build.noindex/bootstrap-XXXXXX")" || ap_fail "Cannot prepare the bootstrap."
AP_BOOTSTRAP="$AP_BOOTSTRAP_DIR/Instalar_AirPlay.command"
if [ "$AP_BUILD_ONLY" -eq 1 ]; then
  AP_BOOTSTRAP="$AP_BOOTSTRAP_DIR/Preparar_AirPlay.command"
fi
AP_PACKAGE_ARGS=(--output "$AP_BOOTSTRAP")
if [ "$AP_BUILD_ONLY" -eq 1 ]; then
  AP_PACKAGE_ARGS+=(--build-only)
fi
if [ -n "${AIRPLAY_ICON_FILE:-}" ]; then
  AP_PACKAGE_ARGS+=(--icon-file "$AIRPLAY_ICON_FILE")
fi
"$AP_PYTHON" "$AP_PROJECT/scripts/package-bootstrap.py" "${AP_PACKAGE_ARGS[@]}" || ap_fail "Bootstrap generation failed."
for AP_SETTING in AIRPLAY_CMAKE AIRPLAY_DEPS_PREFIX AIRPLAY_GSTREAMER_ROOT AIRPLAY_SPARKLE_ARCHIVE AIRPLAY_UPSTREAM_REPO AIRPLAY_WORK_ROOT; do
  export "$AP_SETTING"
done
exec /bin/bash "$AP_BOOTSTRAP"
