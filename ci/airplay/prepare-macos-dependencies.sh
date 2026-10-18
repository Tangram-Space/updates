#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-or-later
# CI preparation only: this script refuses local and self-hosted execution.
# The companion workflow requires an explicitly enabled manual public CI run.
# These are the same release bytes used by the Big Sur R2 installer.
set -euo pipefail
umask 077

ap_ci_fail() { printf '\nERROR: %s\n' "$*" >&2; exit 1; }
[ "$#" -eq 0 ] || ap_ci_fail "This script accepts no arguments."
[ "${CI:-}" = true ] && [ "${GITHUB_ACTIONS:-}" = true ] ||
  ap_ci_fail "Run only in an explicitly enabled GitHub Actions job."
[ "${RUNNER_ENVIRONMENT:-}" = github-hosted ] || ap_ci_fail "A GitHub-hosted runner is required."
[ "${RUNNER_OS:-}" = macOS ] && [ "${RUNNER_ARCH:-}" = X64 ] ||
  ap_ci_fail "A GitHub-hosted Intel macOS runner is required."
[ "${GITHUB_SERVER_URL:-}" = https://github.com ] || ap_ci_fail "Unexpected GitHub server."
[ "${GITHUB_EVENT_NAME:-}" = workflow_dispatch ] || ap_ci_fail "Only a manual workflow dispatch is supported."
[ "${AIRPLAY_PUBLIC_CI_ENABLED:-}" = true ] || ap_ci_fail "Public CI has not been explicitly enabled."
[ "${GITHUB_REPOSITORY:-}" = Tangram-Space/updates ] || ap_ci_fail "This integration belongs to Tangram-Space/updates."
[ "${GITHUB_REF:-}" = refs/heads/main ] || ap_ci_fail "Only the reviewed main branch can run this integration."
[ "$(/usr/bin/uname -s)" = Darwin ] && [ "$(/usr/bin/uname -m)" = x86_64 ] ||
  ap_ci_fail "This script builds only on Intel macOS."
[ "$(/usr/bin/id -u)" -ne 0 ] || ap_ci_fail "Run as the standard ephemeral runner user, not root."

AP_CI_PYTHON="$(/usr/bin/xcrun --find python3)" || ap_ci_fail "Xcode Python 3 is required."
# Validate the dispatch and temporary paths before creating files or downloading.
"$AP_CI_PYTHON" - <<'PY'
import json
import os
from pathlib import Path

event_path = Path(os.environ['GITHUB_EVENT_PATH'])
with event_path.open(encoding='utf-8') as stream:
    repository = json.load(stream).get('repository', {})
if (repository.get('private') is not False or repository.get('visibility') != 'public'
        or repository.get('full_name') != os.environ.get('GITHUB_REPOSITORY')):
    raise SystemExit('Refusing dependency installation: the dispatch repository must be public.')
temporary = Path(os.environ['RUNNER_TEMP']).resolve(strict=True)
env_file = Path(os.environ['GITHUB_ENV']).resolve(strict=True)
if not temporary.is_dir() or temporary in (Path('/'), Path.home().resolve()):
    raise SystemExit('Unexpected runner temporary directory.')
try:
    env_file.relative_to(temporary)
except ValueError:
    raise SystemExit('GITHUB_ENV is outside the runner temporary directory.')
if not env_file.is_file() or not os.access(str(temporary), os.W_OK):
    raise SystemExit('The runner temporary paths are not usable.')
for value in (str(temporary), str(env_file)):
    if '\n' in value or '\r' in value:
        raise SystemExit('Unexpected newline in a runner path.')
PY

AP_CI_GST="/Library/Frameworks/GStreamer.framework/Versions/1.0"
[ ! -e /Library/Frameworks/GStreamer.framework ] && [ ! -L /Library/Frameworks/GStreamer.framework ] ||
  ap_ci_fail "A GStreamer framework already exists; this job will not replace it."
AP_CI_CC="$(/usr/bin/xcrun --find clang)"
AP_CI_CXX="$(/usr/bin/xcrun --find clang++)"
AP_CI_SDK="$(/usr/bin/xcrun --sdk macosx --show-sdk-path)"
AP_CI_LIPO="$(/usr/bin/xcrun --find lipo)"
[ -x "$AP_CI_CC" ] && [ -x "$AP_CI_CXX" ] && [ -d "$AP_CI_SDK" ] || ap_ci_fail "Xcode tools or SDK are missing."
AP_CI_ROOT="$(/usr/bin/mktemp -d "$RUNNER_TEMP/airplay-dependencies-XXXXXX")"
AP_CI_DOWNLOADS="$AP_CI_ROOT/downloads"
AP_CI_PREFIX="$AP_CI_ROOT/libplist-prefix"
/bin/mkdir "$AP_CI_DOWNLOADS" "$AP_CI_ROOT/tools.noindex" "$AP_CI_ROOT/source" "$AP_CI_PREFIX"

ap_ci_hash() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
ap_ci_fetch() {
  local ap_file ap_expected ap_url ap_ok
  ap_file="$1"; ap_expected="$2"; shift 2
  ap_ok=0
  for ap_url in "$@"; do
    /bin/rm -f "$ap_file.part"
    if /usr/bin/curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
         --connect-timeout 20 --max-time 600 --retry 2 --retry-delay 2 \
         --output "$ap_file.part" "$ap_url"; then
      [ "$(ap_ci_hash "$ap_file.part")" = "$ap_expected" ] || ap_ci_fail "SHA256 mismatch: ${ap_file##*/}"
      /bin/mv "$ap_file.part" "$ap_file"
      ap_ok=1
      break
    fi
  done
  [ "$ap_ok" -eq 1 ] || ap_ci_fail "Could not download ${ap_file##*/} from its fixed official URLs."
  printf 'Verified SHA256 %s  %s\n' "$ap_expected" "${ap_file##*/}"
}

AP_CI_RUNTIME="$AP_CI_DOWNLOADS/gstreamer-1.0-1.28.8-universal.pkg"
AP_CI_DEVEL="$AP_CI_DOWNLOADS/gstreamer-1.0-devel-1.28.8-universal.pkg"
AP_CI_CMAKE_ARCHIVE="$AP_CI_DOWNLOADS/cmake-3.31.12-macos-universal.tar.gz"
AP_CI_PLIST_ARCHIVE="$AP_CI_DOWNLOADS/libplist-2.8.0.tar.bz2"
ap_ci_fetch "$AP_CI_RUNTIME" d371ab04a7632713626836c2fc234e863cc98484c74c473eba99b0fbd9b3a3fe \
  https://gstreamer.freedesktop.org/data/pkg/osx/1.28.8/gstreamer-1.0-1.28.8-universal.pkg \
  https://origin.gstreamer.freedesktop.org/data/pkg/osx/1.28.8/gstreamer-1.0-1.28.8-universal.pkg
ap_ci_fetch "$AP_CI_DEVEL" e6d380bc17be7eccf13e0154567d4718fc9321da822408c7ca0cd808b3d4a3f7 \
  https://gstreamer.freedesktop.org/data/pkg/osx/1.28.8/gstreamer-1.0-devel-1.28.8-universal.pkg \
  https://origin.gstreamer.freedesktop.org/data/pkg/osx/1.28.8/gstreamer-1.0-devel-1.28.8-universal.pkg
ap_ci_fetch "$AP_CI_CMAKE_ARCHIVE" 799af7fd545db9bf1b9cfe72f8095880e727a2d4e0df0e3dffc3bc7b95c2d3b0 \
  https://github.com/Kitware/CMake/releases/download/v3.31.12/cmake-3.31.12-macos-universal.tar.gz
ap_ci_fetch "$AP_CI_PLIST_ARCHIVE" b1f59f7634c58b2481325a23ff4e3bf51574a42d868cbe466d2b39b04550752a \
  https://github.com/libimobiledevice/libplist/releases/download/2.8.0/libplist-2.8.0.tar.bz2

# All four complete archives have passed their pinned hashes before installation.
# The official GStreamer PKGs are not XAR-signed; do not invent a signature gate.
# sudo is noninteractive and is reached only after the ephemeral/public CI guards.
/usr/bin/sudo -n /usr/sbin/installer -pkg "$AP_CI_RUNTIME" -target /
/usr/bin/sudo -n /usr/sbin/installer -pkg "$AP_CI_DEVEL" -target /
AP_CI_PKG="$AP_CI_GST/bin/pkg-config"
[ -x "$AP_CI_PKG" ] && [ -x "$AP_CI_GST/bin/gst-inspect-1.0" ] &&
  [ -f "$AP_CI_GST/lib/libcrypto.a" ] || ap_ci_fail "The installed runtime/SDK is incomplete."
[ "$(PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$AP_CI_GST/lib/pkgconfig" "$AP_CI_PKG" --modversion gstreamer-1.0)" = 1.28.8 ] ||
  ap_ci_fail "Unexpected GStreamer version."
[ "$(PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$AP_CI_GST/lib/pkgconfig" "$AP_CI_PKG" --modversion openssl)" = 3.5.0 ] ||
  ap_ci_fail "The pinned GStreamer SDK must provide OpenSSL 3.5.0."
printf 'Pinned SDK: GStreamer 1.28.8; OpenSSL 3.5.0 (headers and static library).\n'

/usr/bin/tar -xzf "$AP_CI_CMAKE_ARCHIVE" -C "$AP_CI_ROOT/tools.noindex"
AP_CI_CMAKE="$AP_CI_ROOT/tools.noindex/cmake-3.31.12-macos-universal/CMake.app/Contents/bin/cmake"
[ -x "$AP_CI_CMAKE" ] || ap_ci_fail "The official CMake archive has an unexpected layout."
[ "$("$AP_CI_CMAKE" --version | /usr/bin/sed -n '1p')" = 'cmake version 3.31.12' ] || ap_ci_fail "Unexpected CMake version."
/usr/bin/tar -xjf "$AP_CI_PLIST_ARCHIVE" -C "$AP_CI_ROOT/source"
(
  cd "$AP_CI_ROOT/source/libplist-2.8.0"
  export SDKROOT="$AP_CI_SDK" MACOSX_DEPLOYMENT_TARGET=11.0
  export PKG_CONFIG="$AP_CI_PKG" PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$AP_CI_GST/lib/pkgconfig"
  CC="$AP_CI_CC" CXX="$AP_CI_CXX" CFLAGS='-O2 -arch x86_64' CXXFLAGS='-O2 -arch x86_64' \
    ./configure --prefix="$AP_CI_PREFIX" --disable-shared --enable-static \
      --without-cython --without-tools --without-tests
  /usr/bin/make -j2
  /usr/bin/make install
)
[ -f "$AP_CI_PREFIX/lib/libplist-2.0.a" ] || ap_ci_fail "Static libplist was not built."
"$AP_CI_LIPO" "$AP_CI_PREFIX/lib/libplist-2.0.a" -verify_arch x86_64
[ "$(PKG_CONFIG_PATH= PKG_CONFIG_LIBDIR="$AP_CI_PREFIX/lib/pkgconfig" "$AP_CI_PKG" --modversion libplist-2.0)" = 2.8.0 ] ||
  ap_ci_fail "Unexpected libplist version."

# Only public, job-local paths enter subsequent steps. No PATH, key or account changes.
printf 'AIRPLAY_CMAKE=%s\nAIRPLAY_DEPS_PREFIX=%s\nAIRPLAY_GSTREAMER_ROOT=%s\n' \
  "$AP_CI_CMAKE" "$AP_CI_PREFIX" "$AP_CI_GST" >> "$GITHUB_ENV"
printf 'Dependencies prepared for x86_64 with MACOSX_DEPLOYMENT_TARGET=11.0.\n'
printf 'This runner cannot validate execution on the user\047s Big Sur Mac.\n'
