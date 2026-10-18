#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Derive public AirPlay update configuration from an existing Actions secret."""
import argparse
from pathlib import Path
import plistlib
import sys

from sparkle_signing import FEED_URL, main_guard, require


def configure(core, signing, temporary):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--sparkle-archive', required=True)
    parser.add_argument('--feed-url', required=True)
    parser.add_argument('--output', required=True, type=Path)
    args = parser.parse_args()
    feed = core.public_url(args.feed_url)
    require(feed == FEED_URL, 'Use the reviewed stable AirPlay feed in Tangram-Space/updates.')
    output = args.output.expanduser().absolute()
    require(not output.is_symlink(), 'The public configuration may not be a symlink.')
    previous = core.read_config(output) if output.exists() else None
    with core.official_tools(args.sparkle_archive) as tools:
        public = signing.derive_public_key(tools, core)
    config = {'SUFeedURL': feed, 'SUPublicEDKey': public,
              'SparkleKeychainAccount': core.KEYCHAIN_ACCOUNT}
    if previous is not None:
        require(previous == config, 'Existing feed/key configuration differs; automatic key rotation was refused.')
    else:
        output.parent.mkdir(parents=True, exist_ok=True)
        with output.open('xb') as stream:
            plistlib.dump(config, stream, fmt=plistlib.FMT_XML, sort_keys=True)
    print('Public update configuration verified: ' + str(output))
    print('Public Ed25519 key: ' + public)


if __name__ == '__main__':
    sys.exit(main_guard(configure))
