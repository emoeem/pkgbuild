#!/usr/bin/env python3
"""Validate reF1nd's stable release metadata and safely bump sing-box-ebpf."""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

METADATA_URL = "https://raw.githubusercontent.com/reF1nd/sing-box-releases/dev/stable-build-info.json"
SOURCE_REPO = "https://github.com/reF1nd/sing-box.git"
RAW_SOURCE = "https://raw.githubusercontent.com/reF1nd/sing-box"
API_SOURCE = "https://api.github.com/repos/reF1nd/sing-box/contents/protocol/ebpf"
VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)-reF1nd$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


# HTTP statuses worth retrying on a scheduled poll; anything else (404 on a
# vanished tag, 401 on a bad token) is a real problem and must page us.
TRANSIENT_HTTP_STATUS = frozenset({408, 429, 500, 502, 503, 504})
FETCH_ATTEMPTS = 3
FETCH_BACKOFF_SECONDS = (5, 15)
MAX_RETRY_AFTER_SECONDS = 60


def request_headers() -> dict[str, str]:
    """Build the request headers, authenticating whenever a token is present.

    Anonymous GitHub API calls share a 60-requests-per-hour quota per IP; the
    scheduled poll exhausted it on 2026-11-24 and the run died with
    "HTTP Error 403: rate limit exceeded" (run 45295926066). The token is
    optional so the script still runs locally without one.
    """
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


def _fetch(url: str, read):
    for attempt in range(1, FETCH_ATTEMPTS + 1):
        request = urllib.request.Request(url, headers=request_headers())
        try:
            with urllib.request.urlopen(request, timeout=20) as response:
                return read(response)
        except (urllib.error.HTTPError, urllib.error.URLError, TimeoutError) as exc:
            if attempt == FETCH_ATTEMPTS or not transient_error(exc):
                raise
            delay = retry_delay(exc, attempt)
            print(
                f"sing-box-ebpf updater: {exc}; retrying in {delay}s",
                file=sys.stderr,
            )
            time.sleep(delay)
    raise AssertionError("unreachable")


def fetch_json(url: str):
    return _fetch(url, json.load)


def fetch_text(url: str) -> str:
    return _fetch(url, lambda response: response.read().decode("utf-8"))


def version_tuple(version: str) -> tuple[int, int, int]:
    match = VERSION_RE.fullmatch(version)
    if not match:
        raise ValueError(f"unsupported stable release version: {version!r}")
    return tuple(map(int, match.groups()))


def current_values(pkgbuild: str) -> tuple[str, str, str, str]:
    def one(pattern: str, label: str) -> str:
        matches = re.findall(pattern, pkgbuild, re.MULTILINE)
        if len(matches) != 1:
            raise ValueError(f"expected exactly one {label} in PKGBUILD, got {len(matches)}")
        return matches[0]

    tag = one(r"^_tag=([^#\s]+)", "_tag")
    commit = one(r'^_commit=([0-9a-f]{40})', "_commit")
    pkgver = one(r'^pkgver=([^#\s]+)', "pkgver")
    return tag, commit, pkgver, tag.removeprefix("v").removesuffix("-reF1nd")


def validate_release(version: str, source_sha: str) -> str:
    version_tuple(version)
    if not SHA_RE.fullmatch(source_sha):
        raise ValueError(f"invalid source_sha in stable-build-info.json: {source_sha!r}")
    tag = f"v{version}"
    result = subprocess.run(
        ["git", "ls-remote", SOURCE_REPO, f"refs/tags/{tag}", f"refs/tags/{tag}^{{}}"],
        capture_output=True, text=True, check=True, timeout=30,
    )
    tag_shas = {line.split()[0] for line in result.stdout.splitlines() if line.split()}
    if source_sha not in tag_shas:
        raise ValueError(f"release metadata SHA {source_sha} does not match {tag} tag ({sorted(tag_shas)})")

    include = fetch_text(f"{RAW_SOURCE}/{source_sha}/include/ebpf.go")
    option = fetch_text(f"{RAW_SOURCE}/{source_sha}/option/ebpf.go")
    if "with_ebpf" not in include or "protocol/ebpf" not in include:
        raise ValueError(f"{tag} is missing the expected with_ebpf inbound registration")
    if "EBPFInboundOptions" not in option:
        raise ValueError(f"{tag} is missing option/ebpf.go's EBPFInboundOptions")
    entries = fetch_json(f"{API_SOURCE}?ref={source_sha}")
    if not isinstance(entries, list) or not entries:
        raise ValueError(f"{tag} has no protocol/ebpf source directory")
    return tag


def update_files(root: Path, tag: str, source_sha: str, version: str) -> bool:
    pkgbuild_path = root / "packages/sing-box-ebpf/PKGBUILD"
    srcinfo_path = root / "packages/sing-box-ebpf/.SRCINFO"
    pkgbuild = pkgbuild_path.read_text(encoding="utf-8")
    current_tag, current_sha, current_pkgver, current_version = current_values(pkgbuild)
    old_tuple = version_tuple(current_version + "-reF1nd")
    new_tuple = version_tuple(version)

    if new_tuple < old_tuple:
        print(f"stable release {version} is older than pinned {current_version}; no change")
        return False
    if new_tuple == old_tuple:
        if current_sha != source_sha or current_tag != tag:
            raise ValueError("stable version matches PKGBUILD but tag/commit differs; refusing silent tag movement")
        print(f"sing-box-ebpf is already current: {current_pkgver} ({current_sha})")
        return False

    pkgver = version.removesuffix("-reF1nd").replace("-", ".") + ".ref1nd"
    replacements = [
        (r"(?m)^_tag=.*$", f"_tag={tag}"),
        (r"(?m)^_commit=[0-9a-f]{40}.*$", f"_commit={source_sha}   # verified against {tag}"),
        (r"(?m)^pkgver=.*$", f"pkgver={pkgver}"),
        (r"(?m)^pkgrel=.*$", "pkgrel=1"),
    ]
    updated = pkgbuild
    for pattern, replacement in replacements:
        updated, count = re.subn(pattern, replacement, updated)
        if count != 1:
            raise ValueError(f"expected one PKGBUILD match for {pattern!r}, got {count}")
    updated_srcinfo = srcinfo_path.read_text(encoding="utf-8")
    src_replacements = [
        (r"(?m)^\tpkgver = .*?$", f"\tpkgver = {pkgver}"),
        (r"(?m)^\tpkgrel = .*?$", "\tpkgrel = 1"),
        (r"(?m)^\tsource = git\+https://github\.com/reF1nd/sing-box\.git#tag=.*?$", f"\tsource = git+https://github.com/reF1nd/sing-box.git#tag={tag}"),
    ]
    for pattern, replacement in src_replacements:
        updated_srcinfo, count = re.subn(pattern, replacement, updated_srcinfo)
        if count != 1:
            raise ValueError(f"expected one .SRCINFO match for {pattern!r}, got {count}")

    if updated == pkgbuild and updated_srcinfo == srcinfo_path.read_text(encoding="utf-8"):
        return False
    pkgbuild_path.write_text(updated, encoding="utf-8")
    srcinfo_path.write_text(updated_srcinfo, encoding="utf-8")
    print(f"prepared sing-box-ebpf update: {current_pkgver} -> {pkgver} ({tag}, {source_sha})")
    return True


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--apply", action="store_true", help="update PKGBUILD and .SRCINFO after validation")
    parser.add_argument("--metadata-url", default=METADATA_URL, help=argparse.SUPPRESS)
    args = parser.parse_args()
    metadata = fetch_json(args.metadata_url)
    version = metadata.get("version")
    source_sha = metadata.get("source_sha")
    if not isinstance(version, str) or not isinstance(source_sha, str):
        raise ValueError("stable-build-info.json is missing version/source_sha; refusing to treat it as an update")
    if not version and not source_sha:
        # An all-empty template is the upstream pipeline's "no stable build recorded"
        # state (reF1nd resets these fields when it restructures the release
        # workflows, e.g. the 2026-10-25 promote force-push), not corruption.
        print("stable-build-info.json is empty: upstream has no stable build recorded; leaving sing-box-ebpf unchanged")
        return 0
    if not version or not source_sha:
        raise ValueError("stable-build-info.json has only one of version/source_sha; refusing to treat it as an update")
    tag = validate_release(version, source_sha)
    if args.apply:
        update_files(args.root, tag, source_sha, version)
    else:
        print(f"validated stable release: {version} ({tag}, {source_sha}); run with --apply to update")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.SubprocessError, urllib.error.URLError, json.JSONDecodeError) as exc:
        print(f"sing-box-ebpf updater: {exc}", file=sys.stderr)
        raise SystemExit(2)
