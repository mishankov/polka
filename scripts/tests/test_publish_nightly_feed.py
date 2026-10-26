import importlib.util
import json
import subprocess
import unittest
from pathlib import Path
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location(
    "publish_nightly_feed", Path(__file__).resolve().parents[1] / "publish-nightly-feed.py"
)
publisher = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(publisher)


def appcast(version):
    return f'''<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
<channel><item><sparkle:version>{version}</sparkle:version>
<description>{{"ru":"Изменения &amp; исправления", "en":"Changes &amp; fixes"}}</description>
<enclosure url="https://github.com/owner/polka/releases/download/v{version}/polka.zip"
sparkle:edSignature="unchanged-signature" length="123" /></item></channel></rss>
'''.encode()


class GitHub:
    def __init__(self, stable="0.8.0", current="0.7.0.20261010021700.123.1", candidate="v0.8.0"):
        self.candidate = candidate
        self.feeds = {"v0.8.0": appcast(stable)}
        if current is not None:
            self.feeds["nightly"] = appcast(current)
        self.uploaded = None
        self.mutations = []

    def gh(self, *args):
        if args[0] == "api":
            endpoint = args[1].split("/releases/")[1]
            tag = "v0.8.0" if endpoint == "latest" else endpoint.removeprefix("tags/")
            if tag == "nightly" and tag not in self.feeds:
                raise subprocess.CalledProcessError(1, args, stderr=b"gh: Not Found (HTTP 404)")
            return json.dumps({
                "tag_name": tag, "draft": False, "prerelease": tag == "nightly" or "-" in tag,
                "target_commitish": "a" * 40, "assets": [{"name": "appcast.xml"}],
            }).encode()
        if args[:2] == ("release", "download"):
            return self.feeds[args[2]]
        self.mutations.append(args)
        if args[:2] == ("release", "upload"):
            self.uploaded = Path(args[3]).read_bytes()
        return b""

    def publish(self):
        with patch.object(publisher, "gh", self.gh):
            publisher.publish("owner/polka", self.candidate)


class NightlyFeedTests(unittest.TestCase):
    def test_stable_release_reaches_existing_nightly_clients_with_exact_signed_feed(self):
        github = GitHub()
        github.publish()
        self.assertEqual(github.uploaded, github.feeds["v0.8.0"])
        self.assertEqual(github.mutations[-1][2], "nightly")

    def test_newer_nightly_survives_stable_publication_or_retry(self):
        github = GitHub(current="0.8.0.20261026010101.999.2")
        github.publish()
        self.assertEqual(github.uploaded, github.feeds["nightly"])

    def test_nightly_publication_uses_latest_stable_if_build_started_before_release(self):
        github = GitHub(candidate="v0.8.0-nightly.20261010021700.123.1")
        github.feeds[github.candidate] = appcast("0.7.0.20261010021700.123.1")
        github.publish()
        self.assertEqual(github.uploaded, github.feeds["v0.8.0"])

    def test_new_nightly_advances_a_stable_pointer(self):
        github = GitHub(current="0.8.0", candidate="v0.8.1-nightly.20261026010101.1000.1")
        github.feeds[github.candidate] = appcast("0.8.0.20261026010101.1000.1")
        github.publish()
        self.assertEqual(github.uploaded, github.feeds[github.candidate])

    def test_old_workflow_retry_cannot_downgrade_current_pointer(self):
        github = GitHub(current="0.8.0.20261026010101.1000.2",
                        candidate="v0.8.1-nightly.20261026010101.1000.1")
        github.feeds[github.candidate] = appcast("0.8.0.20261026010101.1000.1")
        github.publish()
        self.assertEqual(github.uploaded, github.feeds["nightly"])

    def test_first_publication_creates_pointer_without_changing_latest_stable(self):
        github = GitHub(current=None)
        github.publish()
        self.assertEqual(github.uploaded, github.feeds["v0.8.0"])
        self.assertIn("--latest=false", github.mutations[0])

    def test_unrelated_prerelease_does_not_enter_nightly_channel(self):
        github = GitHub(candidate="v0.9.0-beta.1")
        github.publish()
        self.assertEqual(github.mutations, [])

    def test_retry_recovers_pointer_created_before_a_failed_first_upload(self):
        github = GitHub()
        del github.feeds["nightly"]
        original = github.gh

        def empty_pointer(*args):
            if args[0] == "api" and args[1].endswith("tags/nightly"):
                return json.dumps({"tag_name": "nightly", "draft": False, "assets": []}).encode()
            return original(*args)

        with patch.object(publisher, "gh", empty_pointer):
            publisher.publish("owner/polka", github.candidate)
        self.assertEqual(github.uploaded, github.feeds["v0.8.0"])

    def test_invalid_remote_feed_keeps_previous_pointer(self):
        for invalid in [b"not xml", appcast("0.8.0-beta"), appcast("0.8.0").replace(
            b"<item>", b"<item/><item>"), b'<!DOCTYPE rss><rss/>']:
            with self.subTest(invalid=invalid):
                github = GitHub()
                github.feeds["v0.8.0"] = invalid
                with self.assertRaises((ValueError, publisher.ET.ParseError)):
                    github.publish()
                self.assertEqual(github.mutations, [])

    def test_download_and_api_failures_do_not_overwrite_previous_feed(self):
        for operation in ["api", "download"]:
            github = GitHub()
            original = github.gh

            def fail(*args):
                if ((operation == "api" and args[0] == "api" and args[1].endswith("tags/nightly"))
                        or (operation == "download" and args[:2] == ("release", "download"))):
                    raise subprocess.CalledProcessError(1, "gh", stderr=b"HTTP 403 / network error")
                return original(*args)

            with patch.object(publisher, "gh", fail), self.assertRaises(subprocess.CalledProcessError):
                publisher.publish("owner/polka", github.candidate)
            self.assertEqual(github.mutations, [])

    def test_draft_cannot_become_an_update(self):
        github = GitHub()
        original = github.gh

        def draft(*args):
            response = original(*args)
            if args[0] == "api" and args[1].endswith("tags/" + github.candidate):
                metadata = json.loads(response)
                metadata["draft"] = True
                return json.dumps(metadata).encode()
            return response

        with patch.object(publisher, "gh", draft), self.assertRaises(ValueError):
            publisher.publish("owner/polka", github.candidate)
        self.assertEqual(github.mutations, [])

    def test_numeric_ordering_uses_build_version(self):
        versions = ["0.9.0", "0.9.0.20261026123456.99.1", "0.10.0", "0.10.0.20261026123456.100.1"]
        self.assertEqual(sorted(reversed(versions), key=lambda v: publisher.build_version(appcast(v))), versions)
        self.assertEqual(publisher.build_version(appcast("1.0.0")), publisher.build_version(appcast("1")))


if __name__ == "__main__":
    unittest.main()
