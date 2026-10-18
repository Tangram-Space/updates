#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Shared helpers. Source only from this project's scripts.
set -uo pipefail
umask 077

AP_PROJECT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)" || exit 1
if [ -r "$AP_PROJECT/config/local.env" ]; then . "$AP_PROJECT/config/local.env"; fi
. "$AP_PROJECT/version.env"
AP_LOG="${AP_LOG:-}"

ap_fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
ap_note() {
  printf '%s\n' "$*"
  if [ -n "$AP_LOG" ]; then printf '%s %s\n' "$(/bin/date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*" >> "$AP_LOG"; fi
}
ap_run() {
  if [ -n "$AP_LOG" ]; then
    "$@" 2>&1 | /usr/bin/tee -a "$AP_LOG" || ap_fail "Command failed: $1"
  else
    "$@" || ap_fail "Command failed: $1"
  fi
}
ap_sha256() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
ap_require_hash() {
  [ -r "$1" ] || ap_fail "Missing file: $1"
  [ "$(ap_sha256 "$1")" = "$2" ] || ap_fail "SHA256 mismatch: $1"
}
ap_verify_manifest() {
  [ -r "$2" ] || ap_fail "Missing manifest: $2"
  (cd "$1" && /usr/bin/shasum -a 256 -c "$2") || ap_fail "Manifest mismatch: $2"
}
ap_require_mac() {
  [ "$(/usr/bin/uname -s)" = Darwin ] || ap_fail "Run this build on macOS."
  [ "$(/usr/bin/uname -m)" = x86_64 ] || ap_fail "This release targets Intel x86_64."
}
ap_plist() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null; }
ap_is_ours() {
  [ -d "$1" ] && [ ! -L "$1" ] || return 1
  [ "$(ap_plist "$1" CFBundleIdentifier)" = "$AIRPLAY_BUNDLE_ID" ] || return 1
  [ "$(ap_plist "$1" CFBundleExecutable)" = uxplay ] || return 1
  local AP_MARKER AP_SCHEMA
  AP_MARKER=""; AP_SCHEMA=""
  { IFS= read -r AP_MARKER && IFS= read -r AP_SCHEMA; } < "$1/Contents/Resources/installation.txt" 2>/dev/null || return 1
  [ "$AP_MARKER" = "$AIRPLAY_BUNDLE_ID" ] && [ "$AP_SCHEMA" = 1 ]
}
ap_receivers_closed() {
  local AP_NAME AP_PIDS AP_PID AP_EXECUTABLE AP_ACTIVE
  AP_ACTIVE=0
  for AP_NAME in uxplay AirServer; do
    AP_PIDS="$(/usr/bin/pgrep -x "$AP_NAME" 2>/dev/null)" || AP_PIDS=""
    [ -n "$AP_PIDS" ] || continue
    while IFS= read -r AP_PID; do
      case "$AP_PID" in ''|*[!0-9]*) continue ;; esac
      AP_EXECUTABLE="$(LC_ALL=C /bin/ps -ww -p "$AP_PID" -o comm= 2>/dev/null |
        /usr/bin/sed 's/^[[:space:]]*//; s/[[:space:]]*$//')" || AP_EXECUTABLE=""
      if [ -z "$AP_EXECUTABLE" ]; then
        AP_EXECUTABLE="path unavailable during check"
      else
        case "$AP_EXECUTABLE" in "$AP_NAME"|*/"$AP_NAME") : ;; *) continue ;; esac
      fi
      AP_ACTIVE=1
      ap_note "Active receiver: name=$AP_NAME PID=$AP_PID executable=$AP_EXECUTABLE"
    done <<< "$AP_PIDS"
  done
  [ "$AP_ACTIVE" -eq 0 ] || ap_fail "Close the receiver from its menu, or stop its Terminal with Control+C, then retry."
}

