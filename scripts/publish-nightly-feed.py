#!/usr/bin/env python3
"""Advance the existing nightly URL to the newest stable or nightly build.

Both publishing workflows must hold the shared polka-update-feed concurrency
group. Copy the verified appcast bytes; never rewrite signatures or archive URLs.
"""

import argparse
import json
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET
from pathlib import Path
from urllib.parse import quote

SPARKLE = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"


def gh(*args):
    return subprocess.run(
        ["gh", *args], check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    ).stdout


def release(repository, endpoint, optional=False):
    try:
        return json.loads(gh("api", f"repos/{repository}/releases/{endpoint}"))
    except subprocess.CalledProcessError as error:
        if optional and b"(HTTP 404)" in error.stderr:
            return None
        raise


def feed(repository, metadata):
    if metadata["draft"]:
        raise ValueError("Cannot publish a feed from a draft release")
    return gh(
        "release", "download", metadata["tag_name"], "--repo", repository,
        "--pattern", "appcast.xml", "--output", "-",
    )


def build_version(data):
    if len(data) > 1_048_576 or b"<!DOCTYPE" in data.upper():
        raise ValueError("Invalid appcast XML")
    root = ET.fromstring(data)
    channels = root.findall("channel")
    if root.tag != "rss" or len(channels) != 1:
        raise ValueError("Expected one appcast channel")
    items = channels[0].findall("item")
    if len(items) != 1:
        raise ValueError("Expected one verified release item")
    versions = items[0].findall(SPARKLE + "version")
    if len(versions) != 1 or not re.fullmatch(r"[0-9]+(?:\.[0-9]+)*", versions[0].text or ""):
        raise ValueError("Expected a numeric Sparkle build version")
    # ReleaseVersion.buildVersion already orders nightlies below the next stable
    # patch. Compare that numeric value, not shortVersionString or publication date.
    parts = [int(part) for part in versions[0].text.split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def publish(repository, tag):
    candidate = release(repository, "tags/" + quote(tag, safe=""))
    if candidate["draft"]:
        raise ValueError("Release must be published before advancing the feed")
    if candidate["prerelease"] and "-nightly." not in candidate["tag_name"]:
        print("Skipping a prerelease outside the nightly channel")
        return
    stable = release(repository, "latest")
    if stable["prerelease"]:
        raise ValueError("Latest stable release is a prerelease")
    current = release(repository, "tags/nightly", optional=True)
    feeds = [feed(repository, stable), feed(repository, candidate)]
    # A failed first upload may leave a newly created pointer with no assets.
    # Existing feeds must download and parse successfully before any replacement.
    if current is not None and current["assets"]:
        feeds.append(feed(repository, current))
    selected = max(feeds, key=build_version)
    with tempfile.TemporaryDirectory(prefix="polka-update-feed-") as directory:
        path = Path(directory) / "appcast.xml"
        path.write_bytes(selected)
        if current is None:
            gh(
                "release", "create", "nightly", "--repo", repository,
                "--target", candidate["target_commitish"], "--prerelease", "--latest=false",
                "--title", "Polka nightly channel",
                "--notes", "Newest signed stable or nightly build. Select Nightly in Settings → About → Updates.",
            )
        gh("release", "edit", "nightly", "--prerelease", "--latest=false", "--repo", repository)
        gh("release", "upload", "nightly", str(path), "--clobber", "--repo", repository)
    print("Nightly feed build: " + ".".join(map(str, build_version(selected))))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--tag", required=True)
    args = parser.parse_args()
    publish(args.repository, args.tag)
