#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
. "$(dirname "$0")/common.sh"
[ "$#" -eq 1 ] || ap_fail "Usage: prepare-source.sh NEW_SOURCE_DIRECTORY"
AP_SOURCE="$1"
[ ! -e "$AP_SOURCE" ] && [ ! -L "$AP_SOURCE" ] || ap_fail "Source destination already exists: $AP_SOURCE"
/bin/mkdir -p "$AP_SOURCE" || ap_fail "Cannot create source directory."
AP_SOURCE="$(cd "$AP_SOURCE" && pwd -P)" || exit 1
AP_REPO="${AIRPLAY_UPSTREAM_REPO:-}"
if [ -z "$AP_REPO" ]; then
  AP_GIT_CACHE="$(/usr/bin/mktemp -d "${TMPDIR:-/tmp}/airplay-upstream-XXXXXX")" || ap_fail "Cannot create a source cache."
  AP_REPO="$AP_GIT_CACHE/upstream.git"
  ap_run /usr/bin/git init --bare "$AP_REPO"
  ap_run /usr/bin/git -C "$AP_REPO" fetch --depth 1 "$AIRPLAY_UPSTREAM_URL" "$AIRPLAY_UPSTREAM_COMMIT"
  ap_note "Pinned source cache: $AP_REPO"
fi
ap_run /usr/bin/git -C "$AP_REPO" cat-file -e "$AIRPLAY_UPSTREAM_COMMIT^{commit}"
if ! /usr/bin/git -C "$AP_REPO" archive --format=tar "$AIRPLAY_UPSTREAM_COMMIT" | /usr/bin/tar -xf - -C "$AP_SOURCE"; then
  ap_fail "Could not extract the pinned upstream source."
fi
ap_verify_manifest "$AP_SOURCE" "$AP_PROJECT/manifests/upstream.sha256"
ap_verify_manifest "$AP_PROJECT/overlay" "$AP_PROJECT/manifests/overlay.sha256"
/bin/cp -R "$AP_PROJECT/overlay/." "$AP_SOURCE/" || ap_fail "Cannot apply the source overlay."
ap_verify_manifest "$AP_SOURCE" "$AP_PROJECT/manifests/overlay.sha256"
ap_note "Source prepared at $AP_SOURCE"

