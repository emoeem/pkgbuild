#!/usr/bin/env python3
"""The sing-box-ebpf build mode is decided: compile from the pinned source.

On 2026-10-12 the choice between (A) building this package from the reF1nd source
tag and (B) wrapping reF1nd's prebuilt static binary was settled as A, and the
rationale is written into the PKGBUILD header. These checks pin the mechanics
that option A is kept *for*, so moving to the prebuilt upstream binary has to be
a deliberate rewrite of `source=`/`prepare()`/`build()` instead of a quiet edit:

* the source is the git tag URL, so a checked-out tree exists for prepare();
* `_commit` is a full 40-hex pin and prepare() refuses a tag that moved off it;
* `sha256sums=('SKIP')` matches a git source (a real checksum would mean an
  archive, i.e. option B);
* the build is `CGO_ENABLED=0` with an explicit `with_ebpf` tag, and the binary
  is checked to really carry that tag;
* `.SRCINFO` carries the same pinned source line, so the metadata cannot drift.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PKGBUILD = ROOT / "packages/sing-box-ebpf/PKGBUILD"
SRCINFO = ROOT / "packages/sing-box-ebpf/.SRCINFO"

SOURCE_RE = re.compile(
    r'^source=\("git\+https://github\.com/reF1nd/sing-box\.git#tag=\$\{_tag\}"\)$',
    re.MULTILINE,
)
COMMIT_RE = re.compile(r"^_commit=([0-9a-f]{40})\b", re.MULTILINE)
TAG_RE = re.compile(r"^_tag=(\S+)", re.MULTILINE)


def pkgbuild() -> str:
    return PKGBUILD.read_text(encoding="utf-8")


def function_body(name: str) -> str:
    """Return the text of one PKGBUILD shell function."""
    match = re.search(
        rf"^{name}\(\) \{{\n(.*?)^\}}$", pkgbuild(), re.MULTILINE | re.DOTALL
    )
    assert match, f"PKGBUILD has no {name}() function"
    return match.group(1)


class BuildModeTests(unittest.TestCase):
    def test_source_is_the_pinned_git_tag(self):
        self.assertRegex(pkgbuild(), SOURCE_RE)
        # A git source carries no checksum; a real digest would mean an archive.
        self.assertIn("sha256sums=('SKIP')", pkgbuild())

    def test_commit_pin_is_enforced_before_building(self):
        match = COMMIT_RE.search(pkgbuild())
        self.assertIsNotNone(match, "PKGBUILD must pin _commit to a full 40-hex sha")
        prepare = function_body("prepare")
        self.assertIn("git rev-parse HEAD", prepare)
        self.assertIn('"$actual_commit" != "$_commit"', prepare)
        self.assertIn("return 1", prepare)

    def test_build_is_static_go_carrying_with_ebpf(self):
        build = function_body("build")
        self.assertIn("CGO_ENABLED=0", build)
        self.assertRegex(pkgbuild(), re.compile(r"^    with_ebpf$", re.MULTILINE))
        # The tag list is this package's own, not upstream's build.yml.
        self.assertIn("go version -m sing-box | grep -q 'with_ebpf'", build)

    def test_srcinfo_source_matches_the_pinned_tag(self):
        tag = TAG_RE.search(pkgbuild())
        self.assertIsNotNone(tag)
        self.assertIn(
            f"\tsource = git+https://github.com/reF1nd/sing-box.git#tag={tag.group(1)}",
            SRCINFO.read_text(encoding="utf-8"),
        )


if __name__ == "__main__":
    unittest.main()
