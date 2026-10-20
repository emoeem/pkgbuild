#!/usr/bin/env python3
"""Pin the latest stable Filee Linux x64 release into packages/filee-bin.

The package repackages upstream's prebuilt tarball, so an update is a version
bump plus a checksum. Both are derived from the GitHub release itself, never
typed by hand:

  * the release tag must be vMAJOR.MINOR.PATCH and the release stable
    (`releases/latest` already excludes drafts and prereleases);
  * the published `Filee-<version>-linux-x64-SHA256SUMS.txt` asset must name
    the tarball, and its digest must agree with the asset digest GitHub reports;
  * a newer version bumps pkgver/pkgrel and pins the checksum in PKGBUILD and
    .SRCINFO together;
  * the same version with a different checksum is an error, not an update:
    silently repinning a published tag would make "1.12.0" mean two different
    artifacts.

The candidate build in .github/workflows/filee-update.yml is what proves the
tarball still has the expected layout and starts; this script only decides
which release to pin.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path

REPOSITORY = "KnifeLemon/Filee"
LATEST_RELEASE_URL = f"https://api.github.com/repos/{REPOSITORY}/releases/latest"
PKGBUILD_PATH = Path("packages/filee-bin/PKGBUILD")
SRCINFO_PATH = Path("packages/filee-bin/.SRCINFO")
VERSION_RE = re.compile(r"^v?(\d+)\.(\d+)\.(\d+)$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
TARBALL_NAME = "Filee-{version}-linux-x64.tar.gz"
SUMS_NAME = "Filee-{version}-linux-x64-SHA256SUMS.txt"


def request_headers() -> dict[str, str]:
    headers = {
        "Accept": "application/vnd.github+json",
        "User-Agent": "emoeem-pkgbuild-updater",
        "X-GitHub-Api-Version": "2022-11-28",
    }
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token:
        headers["Authorization"] = f"Bearer {token}"
    return headers


def fetch_bytes(url: str) -> bytes:
    request = urllib.request.Request(url, headers=request_headers())
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def fetch_json(url: str):
    return json.loads(fetch_bytes(url))


def fetch_text(url: str) -> str:
    return fetch_bytes(url).decode("utf-8")


def version_tuple(value: str, label: str = "version") -> tuple[int, int, int]:
    match = VERSION_RE.fullmatch(value.strip())
    if not match:
        raise ValueError(f"unsupported {label} {value!r}; expected vMAJOR.MINOR.PATCH")
    return tuple(int(part) for part in match.groups())


def parse_sums(text: str, filename: str) -> str:
    """Return the SHA-256 line for filename in sha256sum output."""
    for line in text.splitlines():
        fields = line.split()
        if len(fields) == 2 and fields[1].lstrip("*") == filename:
            checksum = fields[0].lower()
            if not SHA256_RE.fullmatch(checksum):
                raise ValueError(f"invalid SHA-256 for {filename} in the published sums file")
            return checksum
    raise ValueError(f"{filename} is missing from the published SHA-256 sums file")


def release_assets(release: dict, version: str) -> tuple[dict, dict]:
    assets = {
        asset.get("name"): asset
        for asset in release.get("assets") or []
        if isinstance(asset, dict)
    }
    tarball_name = TARBALL_NAME.format(version=version)
    sums_name = SUMS_NAME.format(version=version)
    missing = [name for name in (tarball_name, sums_name) if name not in assets]
    if missing:
        raise ValueError(
            f"release v{version} does not publish {', '.join(missing)} yet"
        )
    for name in (tarball_name, sums_name):
        state = assets[name].get("state")
        if state is not None and state != "uploaded":
            raise ValueError(f"release asset {name} is in state {state!r}, not uploaded")
    return assets[tarball_name], assets[sums_name]


def expected_checksum(tarball: dict, sums_text: str) -> str:
    """Cross-check the sums file against GitHub's own digest for the asset."""
    filename = tarball.get("name")
    if not isinstance(filename, str) or not filename:
        raise ValueError("the tarball asset has no name")
    checksum = parse_sums(sums_text, filename)
    digest = tarball.get("digest")
    if digest:
        algorithm, _, value = digest.partition(":")
        if algorithm != "sha256" or not SHA256_RE.fullmatch(value or ""):
            raise ValueError(f"unsupported asset digest {digest!r}")
        if value != checksum:
            raise ValueError(
                f"asset digest {value} does not match {filename}'s sums entry {checksum}"
            )
    return checksum


def current_values(pkgbuild: str) -> tuple[str, str, str]:
    def one(pattern: str, label: str) -> str:
        matches = re.findall(pattern, pkgbuild, re.MULTILINE)
        if len(matches) != 1:
            raise ValueError(f"expected exactly one {label} in PKGBUILD, got {len(matches)}")
        return matches[0]

    pkgver = one(r"^pkgver=([^\s#]+)", "pkgver")
    pkgrel = one(r"^pkgrel=([0-9]+(?:\.[0-9]+)?)", "pkgrel")
    sha256 = one(r"^sha256sums=\('([0-9a-f]{64})'\)$", "sha256sums")
    return pkgver, pkgrel, sha256


def replace_once(text: str, pattern: str, replacement: str, label: str) -> str:
    updated, count = re.subn(pattern, replacement, text, flags=re.MULTILINE)
    if count != 1:
        raise ValueError(f"expected exactly one {label} to update, got {count}")
    return updated


def update_files(root: Path, version: str, checksum: str) -> bool:
    pkgbuild_path = root / PKGBUILD_PATH
    srcinfo_path = root / SRCINFO_PATH
    pkgbuild = pkgbuild_path.read_text(encoding="utf-8")
    srcinfo = srcinfo_path.read_text(encoding="utf-8")

    current_pkgver, _, current_checksum = current_values(pkgbuild)
    current = version_tuple(current_pkgver, "pkgver")
    target = version_tuple(version)
    if target < current:
        print(f"Filee {version} is older than the pinned {current_pkgver}; no change")
        return False
    if target == current:
        if current_checksum != checksum:
            raise ValueError(
                f"Filee {version} is pinned with {current_checksum}, but the release "
                f"now publishes {checksum}; refusing to silently repin a published tag"
            )
        print(f"filee-bin is already current: {current_pkgver} ({current_checksum})")
        return False

    updated_pkgbuild = pkgbuild
    for pattern, replacement, label in (
        (r"^pkgver=.*$", f"pkgver={version}", "pkgver"),
        (r"^pkgrel=.*$", "pkgrel=1", "pkgrel"),
        (r"^sha256sums=\('[^']*'\)$", f"sha256sums=('{checksum}')", "sha256sums"),
    ):
        updated_pkgbuild = replace_once(updated_pkgbuild, pattern, replacement, label)

    tarball = TARBALL_NAME.format(version=version)
    source_url = (
        f"https://github.com/{REPOSITORY}/releases/download/v{version}/{tarball}"
    )
    updated_srcinfo = srcinfo
    for pattern, replacement, label in (
        (r"^\tpkgver = .*$", f"\tpkgver = {version}", ".SRCINFO pkgver"),
        (r"^\tpkgrel = .*$", "\tpkgrel = 1", ".SRCINFO pkgrel"),
        (r"^\tsource = .*$", f"\tsource = {source_url}", ".SRCINFO source"),
        (r"^\tsha256sums = .*$", f"\tsha256sums = {checksum}", ".SRCINFO sha256sums"),
    ):
        updated_srcinfo = replace_once(updated_srcinfo, pattern, replacement, label)

    if updated_pkgbuild == pkgbuild and updated_srcinfo == srcinfo:
        print(f"filee-bin is already current: {current_pkgver}")
        return False
    pkgbuild_path.write_text(updated_pkgbuild, encoding="utf-8")
    srcinfo_path.write_text(updated_srcinfo, encoding="utf-8")
    print(f"prepared filee-bin update: {current_pkgver} -> {version} ({checksum})")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--apply", action="store_true", help="write PKGBUILD and .SRCINFO")
    parser.add_argument("--release-url", default=LATEST_RELEASE_URL, help=argparse.SUPPRESS)
    args = parser.parse_args()

    release = fetch_json(args.release_url)
    if release.get("draft") or release.get("prerelease"):
        raise ValueError("latest release is a draft or prerelease; refusing to package it")
    tag = release.get("tag_name")
    if not isinstance(tag, str) or not tag:
        raise ValueError("latest release has no tag_name")
    version = tag.removeprefix("v")
    version_tuple(version, "release version")

    tarball, sums = release_assets(release, version)
    sums_url = sums.get("browser_download_url")
    if not isinstance(sums_url, str) or not sums_url:
        raise ValueError(f"{sums['name']} has no browser_download_url")
    checksum = expected_checksum(tarball, fetch_text(sums_url))
    print(f"validated Filee {version}: {tarball['name']} sha256:{checksum}")
    if args.apply:
        update_files(args.root, version, checksum)
    else:
        print("dry run; pass --apply to update the package")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, urllib.error.URLError, json.JSONDecodeError) as exc:
        print(f"filee updater: {exc}", file=sys.stderr)
        raise SystemExit(2)
