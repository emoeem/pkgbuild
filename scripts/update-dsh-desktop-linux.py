#!/usr/bin/env python3
"""Pin the newest packagable dsh-desktop-linux release into the repository.

The package repacks upstream's prebuilt x86_64 Arch asset, so an update is a
pkgver bump plus a checksum. Both come from the GitHub release itself, never
typed by hand:

  * releases are scanned newest-first and the first one whose tag matches
    vX.Y.Z or vX.Y.ZrcN AND that publishes
    `dsh-desktop-linux-<version>-1-x86_64.pkg.tar.zst` (uploaded) wins; alpha
    tags carry no Arch asset, so they are skipped by the asset rule rather
    than by name matching;
  * the checksum is the asset's GitHub-computed `digest` field — this release
    page publishes no SHA256SUMS file, so that digest is the only
    machine-readable source; a release whose asset lacks it is an error, not
    an update;
  * a newer version bumps pkgver/pkgrel and pins the checksum in PKGBUILD and
    .SRCINFO together (pkgver is embedded in the asset name, so the source
    URL and noextract line move with it);
  * the same version with a different checksum is an error, not an update:
    silently repinning a published tag would make "0.2.2rc3" mean two
    different artifacts;
  * transient API failures (a stray 504, a dropped connection) are retried
    with backoff, while a persistent failure still exits 2 so the workflow's
    notify job reports it.

The candidate build in .github/workflows/dsh-desktop-linux-update.yml is what
proves the repack still works; this script only decides which release to pin.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

REPOSITORY = "ffyfox/dsh-desktop-linux"
RELEASES_URL = f"https://api.github.com/repos/{REPOSITORY}/releases?per_page=100"
PKGNAME = "dsh-desktop-linux"
PKGBUILD_PATH = Path(f"packages/{PKGNAME}/PKGBUILD")
SRCINFO_PATH = Path(f"packages/{PKGNAME}/.SRCINFO")
# Only x86_64 is packaged here (PKGBUILD arch=('x86_64')); upstream also
# publishes an aarch64 asset that this repository never consumes.
ASSET_NAME = f"{PKGNAME}-{{version}}-1-x86_64.pkg.tar.zst"
TAG_RE = re.compile(r"^v(\d+)\.(\d+)\.(\d+)(?:rc(\d+))?$")
DIGEST_RE = re.compile(r"^sha256:([0-9a-f]{64})$")
# HTTP statuses worth retrying on a scheduled poll; anything else (404 on a
# vanished release, 401 on a bad token) is a real problem and must page us.
TRANSIENT_HTTP_STATUS = frozenset({408, 429, 500, 502, 503, 504})
FETCH_ATTEMPTS = 4
FETCH_BACKOFF_SECONDS = (5, 15, 30)
MAX_RETRY_AFTER_SECONDS = 60


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


def transient_error(exc: Exception) -> bool:
    """True for failures a retry can plausibly fix; HTTPError is a URLError."""
    if isinstance(exc, urllib.error.HTTPError):
        return exc.code in TRANSIENT_HTTP_STATUS
    return isinstance(exc, (urllib.error.URLError, TimeoutError))


def retry_delay(exc: Exception, attempt: int) -> int:
    delay = FETCH_BACKOFF_SECONDS[attempt - 1]
    headers = getattr(exc, "headers", None)
    if isinstance(exc, urllib.error.HTTPError) and headers is not None:
        try:
            delay = max(delay, int(headers.get("Retry-After", "")))
        except (TypeError, ValueError):
            pass
    return min(delay, MAX_RETRY_AFTER_SECONDS)


def fetch_bytes(url: str) -> bytes:
    """GET url; transient failures are retried with backoff like the filee updater."""
    for attempt in range(1, FETCH_ATTEMPTS + 1):
        request = urllib.request.Request(url, headers=request_headers())
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return response.read()
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as exc:
            if attempt == FETCH_ATTEMPTS or not transient_error(exc):
                raise
            delay = retry_delay(exc, attempt)
            print(
                f"dsh-desktop-linux updater: {exc}; retrying in {delay}s "
                f"(attempt {attempt}/{FETCH_ATTEMPTS})",
                file=sys.stderr,
            )
            time.sleep(delay)
    raise AssertionError("unreachable: the last attempt always re-raises")


def version_tuple(value: str) -> tuple[int, int, int, int, int]:
    """0.2.2rc3 -> (0, 2, 2, 0, 3); 0.2.3 -> (0, 2, 3, 1, 0).

    The final-release flag makes 0.2.2rc9 < 0.2.3 and keeps rc numbers
    monotonic inside one series.
    """
    match = TAG_RE.match(f"v{value}" if not value.startswith("v") else value)
    if not match:
        raise ValueError(f"unsupported version {value!r}; expected X.Y.Z or X.Y.ZrcN")
    major, minor, patch, rc = match.groups()
    return (int(major), int(minor), int(patch), 1 if rc is None else 0, int(rc or 0))


def asset_digest(asset: dict) -> str:
    digest = asset.get("digest")
    if not isinstance(digest, str) or not DIGEST_RE.match(digest):
        raise ValueError(
            f"asset {asset.get('name')!r} has no sha256 digest GitHub can vouch for"
        )
    return DIGEST_RE.match(digest).group(1)


def find_release(releases: list) -> tuple[str, str]:
    """Newest release that actually packages an x86_64 Arch asset -> (version, sha256)."""
    for release in releases:
        if release.get("draft"):
            continue
        tag = release.get("tag_name")
        if not isinstance(tag, str) or not TAG_RE.match(tag):
            continue
        version = tag.removeprefix("v")
        asset_name = ASSET_NAME.format(version=version)
        asset = next(
            (
                item
                for item in release.get("assets") or []
                if isinstance(item, dict) and item.get("name") == asset_name
            ),
            None,
        )
        if asset is None:
            # Alpha tags and CI retries that only shipped other formats; keep
            # scanning for the newest release this repository can repackage.
            continue
        if asset.get("state") is not None and asset.get("state") != "uploaded":
            raise ValueError(f"release asset {asset_name} is in state {asset.get('state')!r}")
        return version, asset_digest(asset)
    raise ValueError(
        f"no release of {REPOSITORY} publishes {ASSET_NAME.format(version='<X.Y.Z>')}"
    )


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
    current = version_tuple(current_pkgver)
    target = version_tuple(version)
    if target < current:
        print(f"dsh-desktop-linux {version} is older than the pinned {current_pkgver}; no change")
        return False
    if target == current:
        if current_checksum != checksum:
            raise ValueError(
                f"dsh-desktop-linux {version} is pinned with {current_checksum}, but the "
                f"release now publishes {checksum}; refusing to silently repin a published tag"
            )
        print(f"dsh-desktop-linux is already current: {current_pkgver} ({current_checksum})")
        return False

    asset = ASSET_NAME.format(version=version)
    source_line = (
        f"{asset}::https://github.com/{REPOSITORY}/releases/download/v{version}/{asset}"
    )
    updated_pkgbuild = pkgbuild
    for pattern, replacement, label in (
        (r"^pkgver=.*$", f"pkgver={version}", "pkgver"),
        (r"^pkgrel=.*$", "pkgrel=1", "pkgrel"),
        (r"^sha256sums=\('[^']*'\)$", f"sha256sums=('{checksum}')", "sha256sums"),
    ):
        updated_pkgbuild = replace_once(updated_pkgbuild, pattern, replacement, label)

    # pkgver is embedded in the asset name, so .SRCINFO's noextract and source
    # lines move with the version alongside the checksum itself.
    updated_srcinfo = srcinfo
    for pattern, replacement, label in (
        (r"^\tpkgver = .*$", f"\tpkgver = {version}", ".SRCINFO pkgver"),
        (r"^\tpkgrel = .*$", "\tpkgrel = 1", ".SRCINFO pkgrel"),
        (r"^\tnoextract = .*$", f"\tnoextract = {asset}", ".SRCINFO noextract"),
        (r"^\tsource = .*$", f"\tsource = {source_line}", ".SRCINFO source"),
        (r"^\tsha256sums = .*$", f"\tsha256sums = {checksum}", ".SRCINFO sha256sums"),
    ):
        updated_srcinfo = replace_once(updated_srcinfo, pattern, replacement, label)

    if updated_pkgbuild == pkgbuild and updated_srcinfo == srcinfo:
        print(f"dsh-desktop-linux is already current: {current_pkgver}")
        return False
    pkgbuild_path.write_text(updated_pkgbuild, encoding="utf-8")
    srcinfo_path.write_text(updated_srcinfo, encoding="utf-8")
    print(f"prepared dsh-desktop-linux update: {current_pkgver} -> {version} ({checksum})")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--apply", action="store_true", help="write PKGBUILD and .SRCINFO")
    parser.add_argument("--releases-url", default=RELEASES_URL, help=argparse.SUPPRESS)
    args = parser.parse_args()

    releases = json.loads(fetch_bytes(args.releases_url))
    if not isinstance(releases, list):
        raise ValueError("unexpected GitHub API response: releases is not a list")
    version, checksum = find_release(releases)
    print(f"validated dsh-desktop-linux release: v{version} sha256:{checksum}")
    if args.apply:
        update_files(args.root, version, checksum)
    else:
        print("dry run; pass --apply to update the package")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, urllib.error.URLError, json.JSONDecodeError) as exc:
        print(f"dsh-desktop-linux updater: {exc}", file=sys.stderr)
        raise SystemExit(2)
