#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Compare anonymous HTTPS downloads with a make-release output directory.

The local release must already have been signed and verified on the signing
Mac. This read-only check proves byte equality and anonymous availability from
this machine at the time of the check. It does not authenticate an untrusted
local reference, verify EdDSA independently, publish anything, or exercise an
actual macOS/Sparkle update. No artifact or publication flag is written.

Usage: python3 scripts/verify-published-release.py --release-dir RELEASE_DIR
Only the original public URLs can appear in the JSON report. Temporary signed
redirect URLs are validated in memory and are never included in diagnostics.
"""
import argparse
import base64
import hashlib
from http.client import HTTPException
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import ssl
import stat
import sys
import time
from urllib.error import HTTPError, URLError
from urllib.parse import urljoin, urlsplit
from urllib.request import HTTPRedirectHandler, HTTPSHandler, ProxyHandler, Request, build_opener
import xml.etree.ElementTree as ET


MAX_METADATA_BYTES = 64 * 1024
MAX_FEED_BYTES = 4 * 1024 * 1024
MAX_ARCHIVE_BYTES = 512 * 1024 * 1024
CHUNK_BYTES = 64 * 1024
MAX_REDIRECTS = 5
NETWORK_TIMEOUT_SECONDS = 20
DOWNLOAD_DEADLINE_SECONDS = 180
REDIRECT_STATUSES = {301, 302, 303, 307, 308}
RELEASE_KEYS = {
    "bundle_id", "version", "build", "feed_url", "download_url", "archive",
    "archive_sha256", "archive_bytes", "appcast_sha256", "sparkle_version", "published",
}


class VerificationError(ValueError):
    """A diagnostic made only from fixed messages, never a redirected URL."""
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def require(condition, code, message):
    if not condition:
        raise VerificationError(code, message)


def release_helpers():
    """Import validation helpers without creating a __pycache__ alongside them."""
    path = Path(__file__).resolve().with_name("update_release.py")
    spec = importlib.util.spec_from_file_location("airplay_release_validation", str(path))
    require(spec is not None and spec.loader is not None,
            "helper_unavailable", "The existing release validation helper is unavailable.")
    module = importlib.util.module_from_spec(spec)
    prior = sys.dont_write_bytecode
    sys.dont_write_bytecode = True
    try:
        spec.loader.exec_module(module)
    finally:
        sys.dont_write_bytecode = prior
    return module


def regular_file(path):
    """Open a local artifact for reading only; never follow its final symlink."""
    flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        require(not path.is_symlink(), "invalid_local_file", "A local artifact is a symbolic link.")
        fd = os.open(str(path), flags)
    except OSError:
        raise VerificationError("local_file_unavailable", "A required local artifact cannot be read.")
    try:
        require(stat.S_ISREG(os.fstat(fd).st_mode), "invalid_local_file", "A local artifact is not a regular file.")
        return os.fdopen(fd, "rb")
    except BaseException:
        os.close(fd)
        raise


def bounded_local_bytes(path, limit, label):
    with regular_file(path) as stream:
        require(os.fstat(stream.fileno()).st_size <= limit,
                "local_size_limit", label + " exceeds its local size limit.")
        data = stream.read(limit + 1)
    require(0 < len(data) <= limit, "local_size_limit", label + " is empty or exceeds its local size limit.")
    return data


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result, "invalid_metadata", "release.json contains a duplicate key.")
        result[key] = value
    return result


def public_metadata_url(value, helper):
    try:
        return helper.public_url(value)
    except (ValueError, TypeError):
        raise VerificationError("invalid_public_url", "Release URLs must be public HTTPS without credentials, query tokens or fragments.")


def redirect_target(current, location):
    require(isinstance(location, str) and bool(location) and location.isascii() and
            not any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in location),
            "unsafe_redirect", "A redirect has an invalid Location header.")
    try:
        target = urljoin(current, location)
        parts = urlsplit(target)
        allowed = (parts.scheme == "https" and bool(parts.hostname) and bool(parts.path) and
                   parts.port in (None, 443) and parts.username is None and parts.password is None and
                   not parts.fragment and "#" not in target)
    except ValueError:
        allowed = False
    require(allowed, "unsafe_redirect", "A redirect must use standard HTTPS without user information or a fragment.")
    # GitHub release-asset redirects legitimately include temporary SAS queries.
    return target


def one_sparkle_value(item, enclosure, name, expected, helper):
    children = item.findall(helper.SPARKLE_XML + name)
    require(len(children) <= 1, "invalid_appcast", "The release item repeats a Sparkle metadata element.")
    values = [child.text for child in children]
    attribute = enclosure.get(helper.SPARKLE_XML + name)
    if attribute is not None:
        values.append(attribute)
    require(bool(values) and all(value == expected for value in values),
            "appcast_metadata_mismatch", "The appcast release " + name + " does not match release.json.")


def validate_appcast(data, release, helper):
    try:
        text = data.decode("utf-8")
        require(not re.search(r"<!\s*(?:DOCTYPE|ENTITY)\b", text, re.IGNORECASE),
                "invalid_appcast", "The appcast must not contain a DTD or entity declaration.")
        root = ET.fromstring(text)
    except (UnicodeError, ET.ParseError):
        raise VerificationError("invalid_appcast", "The appcast is not valid UTF-8 RSS XML.")
    channels = root.findall("channel")
    require(root.tag == "rss" and root.get("version") == "2.0" and len(channels) == 1,
            "invalid_appcast", "Expected one RSS 2.0 appcast channel, not HTML or another document.")
    items = channels[0].findall("item")
    try:
        builds = [helper.item_build(item) for item in items]
    except ValueError:
        raise VerificationError("invalid_appcast", "An appcast item has an invalid build number.")
    target_build = int(release["build"])
    require(bool(builds) and max(builds) == target_build and builds.count(target_build) == 1,
            "appcast_build_mismatch", "The release build must be the unique newest item in the local appcast.")
    item = items[builds.index(target_build)]
    enclosures = item.findall("enclosure")
    require(len(enclosures) == 1, "invalid_appcast", "The release item must have exactly one full ZIP enclosure.")
    enclosure = enclosures[0]
    one_sparkle_value(item, enclosure, "version", release["build"], helper)
    one_sparkle_value(item, enclosure, "shortVersionString", release["version"], helper)
    one_sparkle_value(item, enclosure, "minimumSystemVersion", "11.0", helper)
    require(enclosure.get("url") == release["download_url"] and
            enclosure.get("length") == str(release["archive_bytes"]),
            "appcast_metadata_mismatch", "The enclosure URL or byte length does not match release.json.")
    signature = enclosure.get(helper.SPARKLE_XML + "edSignature", "")
    try:
        decoded = base64.b64decode(signature, validate=True)
    except (ValueError, TypeError):
        decoded = b""
    require(len(decoded) == 64 and base64.b64encode(decoded).decode("ascii") == signature,
            "invalid_archive_signature", "The enclosure needs a canonical 64-byte EdDSA signature.")
    # release.json binds this signature through appcast_sha256. Signature syntax
    # and equality are checked here; trust comes from the prior Mac verification.
    return signature


def validate_local_release(directory):
    helper = release_helpers()
    directory = Path(directory).expanduser().absolute()
    require(directory.is_dir() and not directory.is_symlink(),
            "invalid_release_directory", "Choose the actual output directory produced by make-release.")
    raw_metadata = bounded_local_bytes(directory / "release.json", MAX_METADATA_BYTES, "release.json")
    try:
        release = json.loads(raw_metadata.decode("utf-8"), object_pairs_hook=unique_object)
    except (UnicodeError, json.JSONDecodeError):
        raise VerificationError("invalid_metadata", "release.json is not valid UTF-8 JSON.")
    require(isinstance(release, dict) and set(release) == RELEASE_KEYS,
            "invalid_metadata", "release.json does not have the make-release metadata fields.")
    require(release["bundle_id"] == helper.BUNDLE_ID and release["sparkle_version"] == helper.SPARKLE_VERSION,
            "invalid_metadata", "The bundle identifier or pinned Sparkle version is unexpected.")
    require(isinstance(release["version"], str) and re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", release["version"]),
            "invalid_metadata", "The release version must be numeric.")
    require(isinstance(release["build"], str) and re.fullmatch(r"[1-9][0-9]*", release["build"]),
            "invalid_metadata", "The release build must be a positive integer string.")
    require(type(release["published"]) is bool, "invalid_metadata", "The existing published field must be a boolean.")
    require(type(release["archive_bytes"]) is int and 0 < release["archive_bytes"] <= MAX_ARCHIVE_BYTES,
            "local_size_limit", "The ZIP byte length is invalid or exceeds 512 MiB.")
    for name in ("archive_sha256", "appcast_sha256"):
        require(isinstance(release[name], str) and re.fullmatch(r"[0-9a-f]{64}", release[name]),
                "invalid_metadata", "A release SHA256 value is invalid.")
    archive_name = "AirPlay-" + release["version"] + "-" + release["build"] + ".zip"
    require(release["archive"] == archive_name, "invalid_metadata", "The ZIP filename does not match the release version and build.")
    public_metadata_url(release["feed_url"], helper)
    public_metadata_url(release["download_url"], helper)
    require(urlsplit(release["download_url"]).path.rsplit("/", 1)[-1] == archive_name,
            "invalid_metadata", "The public ZIP URL does not name this release archive.")

    feed = bounded_local_bytes(directory / "appcast.xml", MAX_FEED_BYTES, "appcast.xml")
    require(hashlib.sha256(feed).hexdigest() == release["appcast_sha256"],
            "local_hash_mismatch", "The local appcast SHA256 does not match release.json.")
    signature = validate_appcast(feed, release, helper)
    archive = directory / archive_name
    digest = hashlib.sha256()
    count = 0
    with regular_file(archive) as stream:
        require(os.fstat(stream.fileno()).st_size == release["archive_bytes"],
                "local_size_mismatch", "The local ZIP length does not match release.json.")
        require(stream.read(4) == b"PK\x03\x04", "invalid_local_archive", "The local archive does not have a ZIP file header.")
        stream.seek(0)
        while True:
            chunk = stream.read(min(CHUNK_BYTES, release["archive_bytes"] - count + 1))
            if not chunk:
                break
            count += len(chunk)
            require(count <= release["archive_bytes"], "local_size_mismatch", "The local ZIP grew while it was being checked.")
            digest.update(chunk)
    require(count == release["archive_bytes"] and digest.hexdigest() == release["archive_sha256"],
            "local_hash_mismatch", "The local ZIP bytes do not match release.json.")
    return {"metadata": release, "feed": feed, "archive": archive, "signature": signature}


class NoAutomaticRedirects(HTTPRedirectHandler):
    # Return the untouched redirect response. urllib's usual redirect path
    # drains its body; this verifier instead closes it without an unbounded read.
    def http_error_302(self, request, response, code, message, headers):
        return response

    http_error_301 = http_error_302
    http_error_303 = http_error_302
    http_error_307 = http_error_302
    http_error_308 = http_error_302


def anonymous_https_opener():
    # Explicitly ignore environment proxies. No credential handler, CookieJar,
    # netrc helper, browser session, Authorization or Referer is used.
    opener = build_opener(ProxyHandler({}), NoAutomaticRedirects(),
                         HTTPSHandler(context=ssl.create_default_context()))
    opener.addheaders = []
    return opener


def download_exact(url, label, expected_bytes, expected_sha256, reference, limit, opener):
    require(0 < expected_bytes <= limit, "download_size_limit", label + " exceeds its download limit.")
    current = url
    visited = {url}
    redirects = 0
    deadline = time.monotonic() + DOWNLOAD_DEADLINE_SECONDS
    while True:
        remaining = deadline - time.monotonic()
        require(remaining > 0, "download_timeout", label + " exceeded its download time limit.")
        request = Request(current, method="GET", headers={
            "User-Agent": "AirPlay-PublicReleaseVerifier/1",
            "Accept-Encoding": "identity",
            "Accept": "application/octet-stream, application/rss+xml, application/xml, text/xml, text/plain",
        })
        response = None
        try:
            response = opener.open(request, timeout=min(NETWORK_TIMEOUT_SECONDS, remaining))
            require(response.geturl() == current, "unexpected_redirect", "The HTTPS transport followed an unchecked redirect.")
            status = response.getcode()
            if status in REDIRECT_STATUSES:
                locations = response.headers.get_all("Location", [])
                require(len(locations) == 1, "unsafe_redirect", "A redirect must have exactly one Location header.")
                target = redirect_target(current, locations[0])
                require(target not in visited, "redirect_loop", label + " encountered a redirect loop.")
                require(redirects < MAX_REDIRECTS, "redirect_limit", label + " exceeded its redirect limit.")
                visited.add(target)
                current = target
                redirects += 1
                continue
            require(status == 200, "http_status", label + " did not return an anonymous HTTP 200 response.")
            encoding = response.headers.get("Content-Encoding", "identity").strip().lower()
            require(encoding in ("", "identity"), "content_encoding", label + " was transferred with an unexpected content encoding.")
            content_type = response.headers.get("Content-Type", "").split(";", 1)[0].strip().lower()
            require(content_type not in ("text/html", "application/xhtml+xml"),
                    "html_response", label + " returned an HTML page instead of the release artifact.")
            lengths = response.headers.get_all("Content-Length", [])
            require(len(lengths) <= 1, "invalid_content_length", label + " has ambiguous Content-Length headers.")
            if lengths:
                require(re.fullmatch(r"[0-9]{1,20}", lengths[0]) is not None,
                        "invalid_content_length", label + " has an invalid Content-Length header.")
                require(int(lengths[0]) == expected_bytes,
                        "content_length_mismatch", label + " advertises a different byte length from the local artifact.")
            digest = hashlib.sha256()
            count = 0
            # HTTPResponse.read1 returns after a buffered/socket read, allowing
            # the deadline to be checked even when a server trickles its body.
            read_chunk = response.read1
            while True:
                require(time.monotonic() < deadline, "download_timeout", label + " exceeded its download time limit.")
                chunk = read_chunk(min(CHUNK_BYTES, expected_bytes - count + 1))
                if not chunk:
                    break
                count += len(chunk)
                require(count <= expected_bytes and count <= limit,
                        "download_size_limit", label + " grew beyond the signed local artifact size.")
                require(reference.read(len(chunk)) == chunk,
                        "download_bytes_mismatch", label + " differs from the signed local artifact.")
                digest.update(chunk)
            require(count == expected_bytes, "download_truncated", label + " ended before the expected byte length.")
            require(not reference.read(1), "local_reference_changed", "A local artifact changed during comparison.")
            require(digest.hexdigest() == expected_sha256,
                    "download_hash_mismatch", label + " SHA256 differs from release.json.")
            return {"url": url, "bytes": count, "sha256": digest.hexdigest(),
                    "redirects_followed": redirects, "bytes_match_local": True}
        except HTTPError as error:
            error.close()
            # HTTPError/URLError text can contain signed redirect URLs. Never
            # format those exceptions or their URL/reason/header fields.
            raise VerificationError("http_status", label + " is not anonymously downloadable with HTTP 200.")
        except (URLError, OSError, HTTPException):
            raise VerificationError("network_error", label + " could not be downloaded over verified HTTPS.")
        finally:
            if response is not None:
                response.close()


def verify_release(directory, opener=None):
    local = validate_local_release(directory)
    metadata = local["metadata"]
    if opener is None:
        opener = anonymous_https_opener()
    feed = download_exact(metadata["feed_url"], "Published appcast", len(local["feed"]),
                          metadata["appcast_sha256"], io.BytesIO(local["feed"]), MAX_FEED_BYTES, opener)
    with regular_file(local["archive"]) as reference:
        archive = download_exact(metadata["download_url"], "Published ZIP", metadata["archive_bytes"],
                                 metadata["archive_sha256"], reference, MAX_ARCHIVE_BYTES, opener)
    return {
        "availability_verified": True,
        "macos_update_test_performed": False,
        "independent_signature_verification_performed": False,
        "artifacts_modified": False,
        "verification_scope": "Unauthenticated HTTPS availability and exact equality to the locally verified release, from this machine at check time.",
        "reference_requirement": "Local artifacts must already have passed make-release signing and verification on macOS; this check does not replace Sparkle EdDSA verification.",
        "bundle_id": metadata["bundle_id"], "version": metadata["version"], "build": metadata["build"],
        "enclosure_signature_matches_local_appcast": True,
        "enclosure_ed_signature": local["signature"],
        "feed": feed, "archive": archive,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--release-dir", required=True, help="Unmodified output directory from make-release.")
    args = parser.parse_args(argv)
    try:
        report = verify_release(args.release_dir)
        code = 0
    except VerificationError as error:
        report = {"availability_verified": False, "macos_update_test_performed": False,
                  "independent_signature_verification_performed": False, "artifacts_modified": False,
                  "error": {"code": error.code, "message": str(error)}}
        code = 1
    except (OSError, ValueError, TypeError, OverflowError):
        # No raw I/O/parser exception can disclose a temporary signed URL.
        report = {"availability_verified": False, "macos_update_test_performed": False,
                  "independent_signature_verification_performed": False, "artifacts_modified": False,
                  "error": {"code": "verification_failed", "message": "The release could not be verified. Check the local make-release output and public hosting."}}
        code = 1
    print(json.dumps(report, indent=2, sort_keys=True))
    return code


if __name__ == "__main__":
    sys.exit(main())
