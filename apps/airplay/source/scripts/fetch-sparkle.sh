#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
. "$(dirname "$0")/common.sh"
[ "$#" -le 1 ] || ap_fail "Usage: fetch-sparkle.sh [NEW_VENDOR_DIRECTORY]"
AP_VENDOR="${1:-$AP_PROJECT/vendor/Sparkle-$AIRPLAY_SPARKLE_VERSION}"
[ ! -e "$AP_VENDOR" ] && [ ! -L "$AP_VENDOR" ] || ap_fail "Destination exists; pass a new directory."
/bin/mkdir -p "$AP_VENDOR" || ap_fail "Cannot create vendor directory."
AP_ARCHIVE="$AP_VENDOR/Sparkle-$AIRPLAY_SPARKLE_VERSION.tar.xz"
ap_run /usr/bin/curl --fail --location --proto '=https' --tlsv1.2 --connect-timeout 20 --max-time 240 --output "$AP_ARCHIVE" "$AIRPLAY_SPARKLE_URL"
ap_require_hash "$AP_ARCHIVE" "$AIRPLAY_SPARKLE_SHA256"
ap_note "Use AIRPLAY_SPARKLE_ARCHIVE=$AP_ARCHIVE"
