#!/usr/bin/env python3
"""Validate reF1nd's stable release metadata and safely bump sing-box-ebpf."""
from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

METADATA_URL = "https://raw.githubusercontent.com/reF1nd/sing-box-releases/dev/stable-build-info.json"
SOURCE_REPO = "https://github.com/reF1nd/sing-box.git"
RAW_SOURCE = "https://raw.githubusercontent.com/reF1nd/sing-box"
API_SOURCE = "https://api.github.com/repos/reF1nd/sing-box/contents/protocol/ebpf"
VERSION_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)-reF1nd$")
SHA_RE = re.compile(r"^[0-9a-f]{40}$")


def fetch_json(url: str):
    request = urllib.request.Request(url, headers={"User-Agent": "emoeem-pkgbuild-updater"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def fetch_text(url: str) -> str:
    request = urllib.request.Request(url, headers={"User-Agent": "emoeem-pkgbuild-updater"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return response.read().decode("utf-8")


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
    if not isinstance(version, str) or not isinstance(source_sha, str) or not version or not source_sha:
        raise ValueError("stable-build-info.json has an empty version/source_sha; refusing to treat it as an update")
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
