#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Offline, synthetic fixtures: no server, signing key, or macOS app is used."""
import base64
from contextlib import redirect_stdout
from email.message import Message
import hashlib
from http.client import IncompleteRead
import importlib.util
import io
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError
import zipfile

sys.dont_write_bytecode = True
SCRIPT = Path(__file__).resolve().parents[1] / "scripts/verify-published-release.py"
SPEC = importlib.util.spec_from_file_location("verify_published_release", str(SCRIPT))
VERIFIER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(VERIFIER)


class Response(io.BytesIO):
    def __init__(self, url, data=b"", status=200, headers=()):
        super().__init__(data)
        self.url = url
        self.status = status
        self.code = status
        self.msg = "Synthetic response"
        self.headers = Message()
        self.read_sizes = []
        self.closed_by_verifier = False
        for key, value in headers:
            self.headers[key] = value

    def geturl(self):
        return self.url

    def getcode(self):
        return self.status

    def info(self):
        return self.headers

    def read1(self, size=-1):
        self.read_sizes.append(size)
        return super().read(size)

    def close(self):
        self.closed_by_verifier = True
        super().close()


class Opener:
    def __init__(self, routes):
        self.routes = routes
        self.requests = []

    def open(self, request, timeout=None):
        self.requests.append(request)
        response = self.routes[request.full_url]
        if isinstance(response, Exception):
            raise response
        return response


class PublicReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="airplay-public-verifier-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.feed_url = "https://updates.example.test/airplay/appcast.xml"
        self.zip_url = "https://downloads.example.test/v1.3.2/AirPlay-1.3.2-6.zip"
        self.zip_name = "AirPlay-1.3.2-6.zip"
        with zipfile.ZipFile(str(self.root / self.zip_name), "w") as archive:
            archive.writestr("AirPlay.app/Contents/Info.plist", "Synthetic test only. " * 10)
        self.archive = (self.root / self.zip_name).read_bytes()
        self.signature = base64.b64encode(b"s" * 64).decode("ascii")
        self.feed = ('''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><title>AirPlay</title><item>
<sparkle:version>6</sparkle:version>
<sparkle:shortVersionString>1.3.2</sparkle:shortVersionString>
<sparkle:minimumSystemVersion>11.0</sparkle:minimumSystemVersion>
<enclosure url="%s" length="%s" type="application/octet-stream" sparkle:edSignature="%s" />
</item></channel></rss>
<!-- sparkle-signatures:
edSignature: %s
length: 1
-->
''' % (self.zip_url, len(self.archive), self.signature, self.signature)).encode("utf-8")
        self.metadata = {
            "bundle_id": "local.chevy.airplay", "version": "1.3.2", "build": "6",
            "feed_url": self.feed_url, "download_url": self.zip_url, "archive": self.zip_name,
            "archive_sha256": hashlib.sha256(self.archive).hexdigest(),
            "archive_bytes": len(self.archive), "appcast_sha256": hashlib.sha256(self.feed).hexdigest(),
            "sparkle_version": "2.9.6", "published": False,
        }
        self.save()

    def save(self):
        (self.root / "appcast.xml").write_bytes(self.feed)
        self.metadata["appcast_sha256"] = hashlib.sha256(self.feed).hexdigest()
        (self.root / "release.json").write_text(json.dumps(self.metadata), encoding="utf-8")

    def opener(self, **overrides):
        routes = {
            self.feed_url: Response(self.feed_url, self.feed, headers=[("Content-Type", "text/plain")]),
            self.zip_url: Response(self.zip_url, self.archive, headers=[("Content-Length", str(len(self.archive)))]),
        }
        routes.update(overrides.get("routes", {}))
        return Opener(routes)

    def check_error(self, expected_code, opener):
        with self.assertRaises(VERIFIER.VerificationError) as caught:
            VERIFIER.verify_release(self.root, opener=opener)
        self.assertEqual(expected_code, caught.exception.code)
        return caught.exception

    def test_success_is_read_only_and_makes_no_macos_or_authenticity_claim(self):
        before = {p.name: p.read_bytes() for p in self.root.iterdir()}
        opener = self.opener()
        report = VERIFIER.verify_release(self.root, opener=opener)
        self.assertTrue(report["availability_verified"])
        self.assertFalse(report["macos_update_test_performed"])
        self.assertFalse(report["independent_signature_verification_performed"])
        self.assertFalse(report["artifacts_modified"])
        self.assertEqual(self.signature, report["enclosure_ed_signature"])
        self.assertEqual(before, {p.name: p.read_bytes() for p in self.root.iterdir()})
        self.assertFalse(json.loads((self.root / "release.json").read_text())["published"])
        for request in opener.requests:
            headers = {key.lower(): value for key, value in request.header_items()}
            self.assertFalse({"authorization", "proxy-authorization", "cookie", "referer"} & set(headers))
            self.assertEqual("identity", headers["accept-encoding"])
            self.assertEqual("GET", request.get_method())
        self.assertTrue(all(response.closed_by_verifier for response in opener.routes.values()))

    def test_local_archive_corruption_stops_before_network(self):
        damaged = self.archive[:-1] + bytes([self.archive[-1] ^ 1])
        (self.root / self.zip_name).write_bytes(damaged)
        opener = self.opener()
        self.check_error("local_hash_mismatch", opener)
        self.assertEqual([], opener.requests)

    def test_local_feed_corruption_stops_before_network(self):
        (self.root / "appcast.xml").write_bytes(self.feed + b" ")
        opener = self.opener()
        self.check_error("local_hash_mismatch", opener)
        self.assertEqual([], opener.requests)

    def test_remote_zip_corruption_is_rejected(self):
        damaged = self.archive[:-1] + bytes([self.archive[-1] ^ 1])
        self.check_error("download_bytes_mismatch", self.opener(routes={self.zip_url: Response(self.zip_url, damaged)}))

    def test_remote_feed_must_match_exact_signed_bytes(self):
        altered = self.feed.replace(b"<title>AirPlay</title>", b"<title>AIRPLAY</title>")
        self.check_error("download_bytes_mismatch", self.opener(routes={self.feed_url: Response(self.feed_url, altered)}))

    def test_html_instead_of_remote_feed_is_rejected(self):
        self.check_error("html_response", self.opener(routes={
            self.feed_url: Response(self.feed_url, b"<html>Sign in</html>", headers=[("Content-Type", "text/html; charset=utf-8")]),
        }))

    def test_html_with_a_forged_xml_type_is_rejected(self):
        html = b"<html>Sign in</html>".ljust(len(self.feed), b" ")
        self.check_error("download_bytes_mismatch", self.opener(routes={
            self.feed_url: Response(self.feed_url, html, headers=[("Content-Type", "application/xml")]),
        }))

    def test_local_html_is_rejected_even_if_manifest_hash_is_updated(self):
        self.feed = b"<html><body>Login</body></html>"
        self.save()
        opener = self.opener()
        self.check_error("invalid_appcast", opener)
        self.assertEqual([], opener.requests)

    def test_dtd_is_rejected_before_xml_entity_expansion(self):
        self.feed = self.feed.replace(b"<rss", b'<!DOCTYPE rss [<!ENTITY test "expanded">]><rss', 1)
        self.save()
        self.check_error("invalid_appcast", self.opener())

    def test_metadata_http_url_is_rejected_without_a_request(self):
        self.metadata["feed_url"] = self.feed_url.replace("https:", "http:")
        self.save()
        opener = self.opener()
        self.check_error("invalid_public_url", opener)
        self.assertEqual([], opener.requests)

    def test_https_redirect_with_github_query_is_allowed_and_never_reported(self):
        temporary_url = "https://release-assets.githubusercontent.com/item.zip?se=TEMPORARY&sig=SECRET"
        redirect = Response(self.zip_url, b"body must never be drained", status=302,
                            headers=[("Location", temporary_url), ("Set-Cookie", "session=SHOULD_NOT_FORWARD")])
        opener = self.opener(routes={self.zip_url: redirect,
                                    temporary_url: Response(temporary_url, self.archive)})
        report = VERIFIER.verify_release(self.root, opener=opener)
        encoded = json.dumps(report)
        self.assertNotIn("TEMPORARY", encoded)
        self.assertNotIn("SECRET", encoded)
        self.assertNotIn(temporary_url, encoded)
        self.assertEqual(1, report["archive"]["redirects_followed"])
        self.assertEqual([], redirect.read_sizes)
        self.assertTrue(redirect.closed_by_verifier)
        self.assertNotIn("Cookie", dict(opener.requests[-1].header_items()))

    def test_relative_redirect_preserves_https(self):
        target = "https://updates.example.test/current.xml"
        opener = self.opener(routes={self.feed_url: Response(self.feed_url, status=307, headers=[("Location", "/current.xml")]),
                                    target: Response(target, self.feed)})
        self.assertTrue(VERIFIER.verify_release(self.root, opener=opener)["availability_verified"])

    def test_real_urllib_handler_chain_with_fake_https_transport(self):
        target = "https://release-assets.githubusercontent.com/test.zip?sig=SECRET"
        routes = self.opener(routes={
            self.zip_url: Response(self.zip_url, b"must not be read", status=302, headers=[("Location", target)]),
            target: Response(target, self.archive),
        }).routes
        requests = []

        class FakeHTTPS(VERIFIER.HTTPSHandler):
            def https_open(self, request):
                requests.append(request)
                return routes[request.full_url]

        opener = VERIFIER.build_opener(VERIFIER.ProxyHandler({}), VERIFIER.NoAutomaticRedirects(), FakeHTTPS())
        opener.addheaders = []
        report = VERIFIER.verify_release(self.root, opener=opener)
        self.assertTrue(report["availability_verified"])
        self.assertEqual([self.feed_url, self.zip_url, target], [request.full_url for request in requests])
        self.assertEqual([], routes[self.zip_url].read_sizes)
        self.assertTrue(all(response.closed_by_verifier for response in routes.values()))
        self.assertNotIn("SECRET", json.dumps(report))

    def test_unsafe_redirects_are_rejected_without_following_them(self):
        targets = [
            "http://downloads.example.test/insecure?sig=SECRET",
            "https://user:password@downloads.example.test/item.zip?sig=SECRET",
            "https://downloads.example.test:8443/item.zip?sig=SECRET",
            "file:///tmp/item.zip", "ftp://downloads.example.test/item.zip",
            "https://downloads.example.test/item.zip#fragment",
            "https://downloads.example.test/item.zip\nInjected: SECRET",
        ]
        for target in targets:
            with self.subTest(target=target):
                response = Response(self.feed_url, status=302, headers=[("Location", target)])
                opener = self.opener(routes={self.feed_url: response})
                error = self.check_error("unsafe_redirect", opener)
                self.assertEqual(1, len(opener.requests))
                self.assertNotIn("SECRET", str(error))
                self.assertNotIn("password", str(error))
                self.assertEqual([], response.read_sizes)

    def test_redirect_loop_is_rejected(self):
        response = Response(self.feed_url, status=301, headers=[("Location", self.feed_url)])
        self.check_error("redirect_loop", self.opener(routes={self.feed_url: response}))

    def test_redirect_count_is_bounded(self):
        routes = {}
        current = self.feed_url
        for index in range(VERIFIER.MAX_REDIRECTS + 1):
            following = "https://updates.example.test/redirect-" + str(index)
            routes[current] = Response(current, status=302, headers=[("Location", following)])
            current = following
        opener = self.opener(routes=routes)
        self.check_error("redirect_limit", opener)
        self.assertEqual(VERIFIER.MAX_REDIRECTS + 1, len(opener.requests))

    def test_redirect_handler_does_not_drain_or_follow_response(self):
        response = Response(self.feed_url, b"unused", status=302, headers=[("Location", "http://blocked.example.test/x")])
        handler = VERIFIER.NoAutomaticRedirects()
        result = handler.http_error_302(None, response, 302, "Found", response.headers)
        self.assertIs(response, result)
        self.assertEqual([], response.read_sizes)

    def test_incorrect_content_length_is_rejected_without_reading_body(self):
        for length in (str(len(self.feed) + 1), str(len(self.feed) - 1)):
            with self.subTest(length=length):
                response = Response(self.feed_url, self.feed, headers=[("Content-Length", length)])
                self.check_error("content_length_mismatch", self.opener(routes={self.feed_url: response}))
                self.assertEqual([], response.read_sizes)

    def test_duplicate_content_length_is_rejected(self):
        response = Response(self.feed_url, self.feed, headers=[("Content-Length", "1"), ("Content-Length", "2")])
        self.check_error("invalid_content_length", self.opener(routes={self.feed_url: response}))

    def test_unadvertised_growth_is_rejected_and_reads_are_bounded(self):
        response = Response(self.feed_url, self.feed + b"x" * 10000)
        with patch.object(VERIFIER, "CHUNK_BYTES", 31):
            self.check_error("download_size_limit", self.opener(routes={self.feed_url: response}))
        self.assertLessEqual(max(response.read_sizes), 31)
        self.assertEqual(len(self.feed) + 1, sum(response.read_sizes))

    def test_truncated_archive_is_rejected(self):
        self.check_error("download_truncated", self.opener(routes={self.zip_url: Response(self.zip_url, self.archive[:-1])}))

    def test_local_feed_and_archive_limits_precede_network(self):
        for constant in ("MAX_FEED_BYTES", "MAX_ARCHIVE_BYTES"):
            with self.subTest(constant=constant), patch.object(VERIFIER, constant, 8):
                opener = self.opener()
                self.check_error("local_size_limit", opener)
                self.assertEqual([], opener.requests)

    def test_version_build_url_size_and_signature_must_be_coherent(self):
        original = self.feed
        cases = [
            (b"<sparkle:version>6</sparkle:version>", b"<sparkle:version>7</sparkle:version>", "appcast_build_mismatch"),
            (b"<sparkle:shortVersionString>1.3.2", b"<sparkle:shortVersionString>1.3.3", "appcast_metadata_mismatch"),
            (self.zip_url.encode(), b"https://downloads.example.test/wrong.zip", "appcast_metadata_mismatch"),
            (("length=\"%s\"" % len(self.archive)).encode(), b'length="1"', "appcast_metadata_mismatch"),
            (self.signature.encode(), base64.b64encode(b"x" * 63), "invalid_archive_signature"),
            (b"<enclosure ", b'<enclosure sparkle:version="99" ', "appcast_metadata_mismatch"),
        ]
        for before, after, code in cases:
            with self.subTest(code=code, before=before[:30]):
                self.feed = original.replace(before, after)
                self.save()
                opener = self.opener()
                self.check_error(code, opener)
                self.assertEqual([], opener.requests)

    def test_duplicate_metadata_key_is_rejected(self):
        text = json.dumps(self.metadata)
        (self.root / "release.json").write_text(text[:-1] + ', "build": "7"}', encoding="utf-8")
        self.check_error("invalid_metadata", self.opener())

    def test_symlink_archive_is_not_followed(self):
        archive = self.root / self.zip_name
        actual = self.root / "actual.zip"
        archive.rename(actual)
        archive.symlink_to(actual)
        self.check_error("invalid_local_file", self.opener())

    def test_transport_http_errors_do_not_disclose_signed_redirects(self):
        signed_url = "https://release-assets.githubusercontent.com/item.zip?sig=SECRET"
        error = HTTPError(signed_url, 403, signed_url, Message(), io.BytesIO(b"error body"))
        opener = self.opener(routes={self.feed_url: Response(self.feed_url, status=302, headers=[("Location", signed_url)]),
                                    signed_url: error})
        with patch.object(VERIFIER, "anonymous_https_opener", return_value=opener), redirect_stdout(io.StringIO()) as output:
            code = VERIFIER.main(["--release-dir", str(self.root)])
        report = json.loads(output.getvalue())
        self.assertEqual(1, code)
        self.assertFalse(report["availability_verified"])
        self.assertFalse(report["macos_update_test_performed"])
        self.assertNotIn("SECRET", output.getvalue())
        self.assertNotIn(signed_url, output.getvalue())

    def test_malformed_http_response_does_not_leak_partial_body(self):
        response = Response(self.feed_url)
        response.read1 = lambda size: (_ for _ in ()).throw(IncompleteRead(b"sig=SECRET", 999))
        error = self.check_error("network_error", self.opener(routes={self.feed_url: response}))
        self.assertNotIn("SECRET", str(error))

    def test_compressed_transfer_is_rejected(self):
        response = Response(self.feed_url, self.feed, headers=[("Content-Encoding", "gzip")])
        self.check_error("content_encoding", self.opener(routes={self.feed_url: response}))

    def test_deadline_is_checked_between_chunks(self):
        with patch.object(VERIFIER.time, "monotonic", side_effect=[0, 0, 181]):
            self.check_error("download_timeout", self.opener())


if __name__ == "__main__":
    unittest.main(verbosity=2)
