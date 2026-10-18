#!/usr/bin/env python3
"""Local-only Sparkle configuration and release preparation for AirPlay.

Private signing material is handled by Sparkle's verified tools in the macOS
Keychain. This script never reads, exports, prints or stores a private key.
It does not contact a server or publish files.
"""
import argparse
import base64
from contextlib import contextmanager
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from urllib.parse import quote, urlsplit
import xml.etree.ElementTree as ET

SPARKLE_VERSION = "2.9.6"
SPARKLE_SHA256 = "52bf9e88cdd972fc0c81501377a880e90d47031bd8ca5462488f843e2609e192"
BUNDLE_ID = "local.chevy.airplay"
KEYCHAIN_ACCOUNT = BUNDLE_ID
SPARKLE_XML = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
PUBLIC_CONFIG_KEYS = {"SUFeedURL", "SUPublicEDKey", "SparkleKeychainAccount"}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def public_url(value, prefix=False):
    require(isinstance(value, str) and bool(value), "A real public HTTPS URL is required.")
    require(value.isascii() and not any(c.isspace() or ord(c) < 32 for c in value),
            "Use an ASCII HTTPS URL; encode spaces and non-ASCII characters.")
    parts = urlsplit(value)
    require(parts.scheme == "https" and bool(parts.hostname) and bool(parts.path),
            "The update URL must be absolute HTTPS with a host and path.")
    require(parts.username is None and parts.password is None and
            not parts.query and not parts.fragment and "?" not in value and "#" not in value,
            "Use a public URL without credentials, query tokens or fragments.")
    require(parts.port in (None, 443), "Use the standard HTTPS port.")
    return value.rstrip("/") + "/" if prefix else value


def public_key(value):
    require(isinstance(value, str), "A public Ed25519 key is required.")
    try:
        decoded = base64.b64decode(value, validate=True)
    except (ValueError, TypeError):
        raise ValueError("The public Ed25519 key is not valid Base64.")
    require(len(decoded) == 32 and base64.b64encode(decoded).decode("ascii") == value,
            "The public Ed25519 key must be exactly 32 bytes in canonical Base64.")
    return value


def read_config(path):
    with Path(path).open("rb") as stream:
        config = plistlib.load(stream)
    require(isinstance(config, dict) and set(config) == PUBLIC_CONFIG_KEYS,
            "UpdateConfig.plist must contain only the public feed, public key and Keychain account.")
    public_url(config["SUFeedURL"])
    public_key(config["SUPublicEDKey"])
    require(config["SparkleKeychainAccount"] == KEYCHAIN_ACCOUNT,
            "Unexpected Keychain account; this release uses local.chevy.airplay.")
    return config


def validate_config(args):
    read_config(args.config)
    print("Public update configuration is valid.")


def run(arguments, capture=False):
    # Never run a shell or interpolate data as a command.
    result = subprocess.run([str(arg) for arg in arguments], check=True,
                            stdout=subprocess.PIPE if capture else None,
                            universal_newlines=True)
    return result.stdout.strip() if capture else None


def require_mac():
    require(sys.platform == "darwin", "Run this operation on the signing Mac, with Xcode tools installed.")


@contextmanager
def official_tools(archive):
    require_mac()
    archive = Path(archive).expanduser().resolve(strict=True)
    require(sha256(archive) == SPARKLE_SHA256, "Sparkle archive SHA256 does not match the official 2.9.6 release.")
    with tempfile.TemporaryDirectory(prefix="AirPlay-Sparkle-") as temporary:
        root = Path(temporary)
        # The archive's complete bytes are pinned before extraction/execution.
        run(["/usr/bin/tar", "-xf", archive, "-C", root])
        framework = root / "Sparkle.framework"
        with (framework / "Resources/Info.plist").open("rb") as stream:
            metadata = plistlib.load(stream)
        require(metadata.get("CFBundleShortVersionString") == SPARKLE_VERSION,
                "Unexpected Sparkle framework version.")
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", framework])
        for tool in ("generate_keys", "generate_appcast", "sign_update"):
            run(["/usr/bin/codesign", "--verify", "--strict", root / "bin" / tool])
        yield root / "bin"


def keychain_public_key(tools):
    # -p returns the public key only. It fails if the account has no key; there
    # is no private-key export/import path in this script.
    return public_key(run([tools / "generate_keys", "--account", KEYCHAIN_ACCOUNT, "-p"], capture=True))


def configure(args):
    require_mac()
    feed = public_url(args.feed_url)
    output = Path(args.output).expanduser().absolute()
    require(not output.is_symlink(), "The output configuration may not be a symlink.")
    prior = read_config(output) if output.exists() else None
    if prior is not None:
        require(prior["SUFeedURL"] == feed,
                "This configuration already has another feed. Keep its signing key and review channel migration explicitly.")
    output.parent.mkdir(parents=True, exist_ok=True)
    with official_tools(args.sparkle_archive) as tools:
        if prior is None:
            # The official default mode reuses an existing account, or creates
            # a new key directly in Keychain. Only public-key instructions print.
            run([tools / "generate_keys", "--account", KEYCHAIN_ACCOUNT])
        key = keychain_public_key(tools)
        if prior is not None:
            require(prior["SUPublicEDKey"] == key,
                    "The Keychain public key differs from this channel. No configuration was changed.")
            print("Public configuration and existing Keychain key already match; no changes needed.")
            return
        config = {"SUFeedURL": feed, "SUPublicEDKey": key, "SparkleKeychainAccount": KEYCHAIN_ACCOUNT}
        # Exclusive creation prevents an accidental overwrite/key rotation.
        with output.open("xb") as stream:
            plistlib.dump(config, stream, fmt=plistlib.FMT_XML, sort_keys=True)
    print("Public update configuration written to: " + str(output))
    print("The private signing key remains in this Mac's Keychain; no private-key file was created.")
    print("Rebuild the app with this public configuration before signing its bundle.")


def app_metadata(app, config):
    with (app / "Contents/Info.plist").open("rb") as stream:
        metadata = plistlib.load(stream)
    require(metadata.get("CFBundleIdentifier") == BUNDLE_ID and
            metadata.get("CFBundleExecutable") == "uxplay", "This is not the expected AirPlay app.")
    marker = (app / "Contents/Resources/installation.txt").read_text(encoding="utf-8").splitlines()
    require(marker[:2] == [BUNDLE_ID, "1"], "The AirPlay installation marker is missing or invalid.")
    version = metadata.get("CFBundleShortVersionString", "")
    build = metadata.get("CFBundleVersion", "")
    require(isinstance(version, str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", version),
            "Use a numeric release version such as 1.3 or 1.3.1.")
    require(isinstance(build, str) and re.fullmatch(r"[1-9][0-9]*", build),
            "CFBundleVersion must be an increasing positive integer.")
    require(metadata.get("LSMinimumSystemVersion") == "11.0", "This release must preserve macOS 11.0 compatibility.")
    for key in ("SUFeedURL", "SUPublicEDKey"):
        require(metadata.get(key) == config[key], "The signed app does not match the public update configuration: " + key)
    for key in ("SURequireSignedFeed", "SUVerifyUpdateBeforeExtraction"):
        require(metadata.get(key) is True, "The app must require signed feeds and archives: " + key)
    for key in ("SUEnableAutomaticChecks", "SUAutomaticallyUpdate", "SUAllowsAutomaticUpdates"):
        require(metadata.get(key) is False, "This app release supports explicit update checks only: " + key)
    return metadata


def item_build(item):
    version = item.findtext(SPARKLE_XML + "version")
    if version is None:
        enclosure = item.find("enclosure")
        version = enclosure.get(SPARKLE_XML + "version") if enclosure is not None else None
    require(isinstance(version, str) and re.fullmatch(r"[1-9][0-9]*", version),
            "An appcast item has a non-integer build number; review it before preparing a release.")
    return int(version)


def read_items(path):
    items = ET.parse(str(path)).getroot().findall("./channel/item")
    require(bool(items), "The appcast contains no update items.")
    return items


def make_release(args):
    require_mac()
    config = read_config(args.config)
    prefix = public_url(args.download_url_prefix, prefix=True)
    app = Path(args.app).expanduser().resolve(strict=True)
    require(app.name == "AirPlay.app" and app.is_dir(), "Choose the built AirPlay.app bundle.")
    metadata = app_metadata(app, config)
    version, build = metadata["CFBundleShortVersionString"], metadata["CFBundleVersion"]
    output = Path(args.output).expanduser().absolute()
    require(not output.exists() and not output.is_symlink(), "Use a new output directory; existing releases are never overwritten.")
    previous = Path(args.previous_appcast).expanduser().resolve(strict=True) if args.previous_appcast else None
    if previous:
        require(int(build) > max(item_build(item) for item in read_items(previous)),
                "Increase CFBundleVersion above every build in the existing feed before preparing a release.")

    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app])
    lipo = run(["/usr/bin/xcrun", "--find", "lipo"], capture=True)
    run([lipo, app / "Contents/MacOS/uxplay", "-verify_arch", "x86_64"])

    with official_tools(args.sparkle_archive) as tools:
        require(keychain_public_key(tools) == config["SUPublicEDKey"],
                "The Mac Keychain signing key does not match the app; no release was prepared.")
        if previous:
            run([tools / "sign_update", "--account", KEYCHAIN_ACCOUNT, "--verify", previous])
        output.parent.mkdir(parents=True, exist_ok=True)
        # Construct inside a temporary sibling. Only expose the final directory
        # after signature, URL, size and build checks pass.
        with tempfile.TemporaryDirectory(prefix=".AirPlay-release-", dir=str(output.parent)) as temporary:
            work = Path(temporary)
            archive = work / ("AirPlay-" + version + "-" + build + ".zip")
            feed = work / "appcast.xml"
            if previous:
                shutil.copyfile(str(previous), str(feed))
            run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive])
            run([tools / "generate_appcast", "--account", KEYCHAIN_ACCOUNT,
                 "--download-url-prefix", prefix, "--maximum-deltas", "0", "--maximum-versions", "0",
                 "--versions", build, "-o", feed, work])
            run([tools / "sign_update", "--account", KEYCHAIN_ACCOUNT, "--verify", feed])
            matches = [item for item in read_items(feed) if item_build(item) == int(build)]
            require(len(matches) == 1, "The generated appcast must have exactly one item for the new build.")
            enclosure = matches[0].find("enclosure")
            require(enclosure is not None, "The generated update has no download enclosure.")
            expected_url = prefix + quote(archive.name)
            require(enclosure.get("url") == expected_url, "The generated download URL does not match this release.")
            require(enclosure.get("length") == str(archive.stat().st_size), "The appcast update size is incorrect.")
            signature = enclosure.get(SPARKLE_XML + "edSignature", "")
            require(len(base64.b64decode(signature, validate=True)) == 64, "Missing or invalid archive EdDSA signature.")
            require(matches[0].findtext(SPARKLE_XML + "minimumSystemVersion") == "11.0",
                    "The generated feed does not preserve macOS 11.0 compatibility.")
            run([tools / "sign_update", "--account", KEYCHAIN_ACCOUNT, "--verify", archive, signature])
            release = {"bundle_id": BUNDLE_ID, "version": version, "build": build,
                       "feed_url": config["SUFeedURL"], "download_url": expected_url,
                       "archive": archive.name, "archive_sha256": sha256(archive),
                       "archive_bytes": archive.stat().st_size, "appcast_sha256": sha256(feed),
                       "sparkle_version": SPARKLE_VERSION, "published": False}
            (work / "release.json").write_text(json.dumps(release, indent=2) + "\n", encoding="utf-8")
            # Copy verified artifacts only, so extraction caches never become a release.
            ready = work / "verified-release"
            ready.mkdir()
            for path in (archive, feed, work / "release.json"):
                shutil.copyfile(str(path), str(ready / path.name))
            require(not output.exists() and not output.is_symlink(), "The output directory appeared during preparation; it was not overwritten.")
            ready.rename(output)
    print("Signed release prepared locally: " + str(output))
    print("Archive destination: " + release["download_url"])
    print("Signed appcast destination: " + release["feed_url"])
    print("Nothing was uploaded. Publish the archive first, then the exact signed appcast bytes.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="operation", required=True)
    validation_parser = subparsers.add_parser("validate-config", help="Validate the public build input without network or Keychain access.")
    validation_parser.add_argument("--config", required=True)
    validation_parser.set_defaults(action=validate_config)
    configure_parser = subparsers.add_parser("configure", help="Create/reuse a Mac Keychain key and write only public configuration.")
    configure_parser.add_argument("--sparkle-archive", required=True)
    configure_parser.add_argument("--feed-url", required=True)
    configure_parser.add_argument("--output", required=True)
    configure_parser.set_defaults(action=configure)
    release_parser = subparsers.add_parser("release", help="Prepare and verify a signed ZIP/appcast without publishing.")
    release_parser.add_argument("--sparkle-archive", required=True)
    release_parser.add_argument("--config", required=True)
    release_parser.add_argument("--app", required=True)
    release_parser.add_argument("--download-url-prefix", required=True)
    release_parser.add_argument("--output", required=True)
    release_parser.add_argument("--previous-appcast")
    release_parser.set_defaults(action=make_release)
    args = parser.parse_args()
    os.umask(0o077)
    try:
        args.action(args)
    except (ValueError, OSError, subprocess.CalledProcessError, ET.ParseError, plistlib.InvalidFileException) as error:
        parser.exit(1, "ERROR: " + str(error) + "\n")


if __name__ == "__main__":
    main()
