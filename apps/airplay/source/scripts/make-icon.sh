#!/bin/bash
# Original native icon generator; compatible with macOS Bash 3.2.
# Produces no app changes: the caller selects an ICNS file and a new work folder.
set -euo pipefail
umask 077

if [ "$#" -ne 2 ]; then
  printf 'Usage: /bin/bash make-icon.sh OUTPUT.icns NEW_WORK_DIRECTORY\n' >&2
  exit 64
fi
if [ "$(/usr/bin/uname -s)" != Darwin ]; then
  printf 'Run this generator on macOS.\n' >&2
  exit 69
fi
AP_ICON_SOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
AP_ICON_OUTPUT="$1"
AP_ICON_WORK="$2"
case "$AP_ICON_OUTPUT" in *.icns) ;; *) printf 'The output must end in .icns.\n' >&2; exit 64 ;; esac
if [ -d "$AP_ICON_OUTPUT" ] || [ -L "$AP_ICON_OUTPUT" ]; then
  printf 'The output must be a regular file path, not a directory or symbolic link.\n' >&2
  exit 73
fi
if [ -e "$AP_ICON_WORK" ] || [ -L "$AP_ICON_WORK" ]; then
  printf 'The work directory must not exist yet: %s\n' "$AP_ICON_WORK" >&2
  exit 73
fi
[ -x /usr/bin/iconutil ] || { printf 'iconutil was not found.\n' >&2; exit 69; }
AP_ICON_CC="$(/usr/bin/xcrun --sdk macosx --find clang)"
AP_ICON_SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
/bin/mkdir "$AP_ICON_WORK"
AP_ICON_WORK="$(cd "$AP_ICON_WORK" && pwd -P)"
"$AP_ICON_CC" -arch x86_64 -isysroot "$AP_ICON_SDK" -mmacosx-version-min=11.0 \
  -fobjc-arc -Wall -Wextra -Werror=objc-method-access \
  "$AP_ICON_SOURCE_DIR/render-icon.m" -framework Cocoa \
  -o "$AP_ICON_WORK/render-icon"
"$AP_ICON_WORK/render-icon" "$AP_ICON_WORK/AirPlay.iconset"
/usr/bin/iconutil -c icns -o "$AP_ICON_WORK/AirPlay.icns" "$AP_ICON_WORK/AirPlay.iconset"
AP_ICON_MAGIC="$(/usr/bin/od -An -N4 -tx1 "$AP_ICON_WORK/AirPlay.icns" | /usr/bin/tr -d ' \n')"
if [ "$AP_ICON_MAGIC" != 69636e73 ]; then
  printf 'The generated file is not an ICNS container.\n' >&2
  exit 74
fi
# The caller should pass a staged Resources path; this never edits Info.plist,
# signs or registers a bundle, or restarts Finder, Dock or the receiver.
/bin/cp "$AP_ICON_WORK/AirPlay.icns" "$AP_ICON_OUTPUT"
/usr/bin/cmp -s "$AP_ICON_WORK/AirPlay.icns" "$AP_ICON_OUTPUT"
printf 'AIRPLAY_ICON ICNS_OK path=%s\n' "$AP_ICON_OUTPUT"
/usr/bin/shasum -a 256 "$AP_ICON_OUTPUT"
