#!/usr/bin/env python3
"""Regression tests for the dsh-desktop-linux release updater.

The bug these lock in (reports/pkgbuild-optimization/dsh-audit.md 5.2): the tag
grammar knew only vX.Y.Z and vX.Y.ZrcN, so once upstream started shipping an
Arch asset for alpha tags (v0.2.3alpha1) the scan skipped both alphas, settled
on v0.2.2rc5 and reported "already current" on every scheduled run.
"""
from __future__ import annotations

import importlib.util
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "update_dsh_desktop_linux", ROOT / "scripts/update-dsh-desktop-linux.py"
)
assert SPEC and SPEC.loader
updater = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(updater)

SHA_ALPHA2 = "0550b1260cd48ff9fb0bbd443d42d30206466ef460484c68fc0e77d5862bdb77"
SHA_OLD = "5ee11541f4f19d23b5743a7eb05c918e1e6cb67e19ca0f5cc27e1dff9c18f8af"


def release(tag, *, version=None, digest=SHA_ALPHA2, state="uploaded", draft=False, formats=("x86_64",)):
    """One GitHub release payload carrying the Arch assets this repository reads."""
    resolved = version if version is not None else tag.removeprefix("v")
    assets = [
        {
            "name": updater.ASSET_NAME.format(version=resolved),
            "state": state,
            "digest": f"sha256:{digest}",
        }
        for arch in formats
        if arch == "x86_64"
    ]
    assets.append({"name": f"dsh-desktop-linux-{resolved}-1-aarch64.pkg.tar.zst", "state": state})
    return {"tag_name": tag, "draft": draft, "assets": assets}


class VersionOrderTests(unittest.TestCase):
    def test_pre_release_levels_are_parsed(self):
        self.assertEqual(updater.version_tuple("0.2.3alpha2"), (0, 2, 3, 0, 2))
        self.assertEqual(updater.version_tuple("0.2.3beta1"), (0, 2, 3, 1, 1))
        self.assertEqual(updater.version_tuple("0.2.2rc5"), (0, 2, 2, 2, 5))
        self.assertEqual(updater.version_tuple("0.2.3"), (0, 2, 3, 3, 0))

    def test_ordering_agrees_with_vercmp(self):
        pairs = [
            ("0.2.2rc5", "0.2.3alpha1"),
            ("0.2.3alpha1", "0.2.3alpha2"),
            ("0.2.3alpha2", "0.2.3beta1"),
            ("0.2.3beta1", "0.2.3rc1"),
            ("0.2.3rc1", "0.2.3"),
            ("0.2.2rc9", "0.2.3alpha1"),
            ("0.2.3alpha9", "0.2.3alpha10"),
        ]
        for older, newer in pairs:
            with self.subTest(pair=(older, newer)):
                self.assertLess(updater.version_tuple(older), updater.version_tuple(newer))
                if _vercmp_available():
                    self.assertEqual("-1", _vercmp(older, newer))

    def test_unknown_version_shapes_are_rejected(self):
        for value in ("", "0.2", "0.2.3.4", "0.2.3-1", "0.2.3gamma1"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                updater.version_tuple(value)

    def test_tag_grammar_rejects_the_unparseable_shape(self):
        self.assertIsNone(updater.TAG_RE.match("v0.1.7rc2-2"))

    def test_compare_versions_distinguishes_equal_older_and_newer(self):
        self.assertEqual(0, updater.compare_versions("0.2.3alpha2", "0.2.3alpha2"))
        self.assertEqual(-1, updater.compare_versions("0.2.2rc5", "0.2.3alpha1"))
        self.assertEqual(1, updater.compare_versions("0.2.3", "0.2.3rc9"))


def _vercmp_available():
    return subprocess.run(["sh", "-c", "command -v vercmp"], capture_output=True).returncode == 0


def _vercmp(a, b):
    return subprocess.run(["vercmp", a, b], capture_output=True, text=True).stdout.strip()


class FindReleaseTests(unittest.TestCase):
    def test_alpha_release_wins_over_older_rc(self):
        releases = [release("v0.2.3alpha2"), release("v0.2.3alpha1"), release("v0.2.2rc5", digest=SHA_OLD)]
        self.assertEqual(("0.2.3alpha2", SHA_ALPHA2), updater.find_release(releases))

    def test_alpha_needs_an_arch_asset_to_win(self):
        releases = [release("v0.2.3alpha2", formats=("deb",)), release("v0.2.2rc5", digest=SHA_OLD)]
        self.assertEqual(("0.2.2rc5", SHA_OLD), updater.find_release(releases))

    def test_draft_release_is_ignored(self):
        releases = [release("v0.2.3alpha2", draft=True), release("v0.2.2rc5", digest=SHA_OLD)]
        self.assertEqual("0.2.2rc5", updater.find_release(releases)[0])

    def test_unfinished_upload_is_an_error(self):
        with self.assertRaisesRegex(ValueError, "state"):
            updater.find_release([release("v0.2.3alpha2", state="starter")])

    def test_missing_digest_is_an_error(self):
        broken = release("v0.2.3alpha2")
        broken["assets"][0]["digest"] = None
        with self.assertRaisesRegex(ValueError, "digest"):
            updater.find_release([broken])


class UnparsableTagGuardTests(unittest.TestCase):
    def test_old_unreadable_tag_stays_quiet(self):
        updater.assert_no_newer_unparsable_tag([{"tag_name": "v0.1.7rc2-2"}], "0.2.2rc5")

    def test_unreadable_tag_at_the_pinned_series_fails(self):
        tags = [{"tag_name": "v0.3.0delta1", "draft": False, "assets": []}]
        with self.assertRaisesRegex(ValueError, "cannot parse"):
            updater.assert_no_newer_unparsable_tag(tags, "0.2.2rc5")

    def test_guard_ignores_readable_tags(self):
        updater.assert_no_newer_unparsable_tag([release("v0.2.3alpha2")], "0.2.2rc5")


PKGBUILD = """pkgname=dsh-desktop-linux
pkgver=0.2.2rc5
pkgrel=1
arch=('x86_64')
source=("dsh-desktop-linux-${pkgver}-1-${CARCH}.pkg.tar.zst::https://github.com/ffyfox/dsh-desktop-linux/releases/download/v${pkgver}/dsh-desktop-linux-${pkgver}-1-${CARCH}.pkg.tar.zst")
noextract=("dsh-desktop-linux-${pkgver}-1-${CARCH}.pkg.tar.zst")
sha256sums=('5ee11541f4f19d23b5743a7eb05c918e1e6cb67e19ca0f5cc27e1dff9c18f8af')
"""

SRCINFO = """pkgbase = dsh-desktop-linux
\tpkgver = 0.2.2rc5
\tpkgrel = 1
\tarch = x86_64
\tnoextract = dsh-desktop-linux-0.2.2rc5-1-x86_64.pkg.tar.zst
\tsource = dsh-desktop-linux-0.2.2rc5-1-x86_64.pkg.tar.zst::https://github.com/ffyfox/dsh-desktop-linux/releases/download/v0.2.2rc5/dsh-desktop-linux-0.2.2rc5-1-x86_64.pkg.tar.zst
\tsha256sums = 5ee11541f4f19d23b5743a7eb05c918e1e6cb67e19ca0f5cc27e1dff9c18f8af

pkgname = dsh-desktop-linux
"""


class UpdateFilesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        (self.root / updater.PKGBUILD_PATH).parent.mkdir(parents=True)
        (self.root / updater.PKGBUILD_PATH).write_text(PKGBUILD, encoding="utf-8")
        (self.root / updater.SRCINFO_PATH).write_text(SRCINFO, encoding="utf-8")
        self.addCleanup(self.tmp.cleanup)

    def read(self):
        return (
            (self.root / updater.PKGBUILD_PATH).read_text(encoding="utf-8"),
            (self.root / updater.SRCINFO_PATH).read_text(encoding="utf-8"),
        )

    def test_alpha_update_moves_every_embedded_version_line(self):
        self.assertTrue(updater.update_files(self.root, "0.2.3alpha2", SHA_ALPHA2))
        pkgbuild, srcinfo = self.read()
        self.assertIn("pkgver=0.2.3alpha2", pkgbuild)
        self.assertIn(f"sha256sums=('{SHA_ALPHA2}')", pkgbuild)
        # The asset name embeds pkgver, so noextract and source move with it.
        self.assertIn(
            "dsh-desktop-linux-0.2.3alpha2-1-x86_64.pkg.tar.zst::"
            "https://github.com/ffyfox/dsh-desktop-linux/releases/download/v0.2.3alpha2/"
            "dsh-desktop-linux-0.2.3alpha2-1-x86_64.pkg.tar.zst",
            srcinfo,
        )
        self.assertIn("\tnoextract = dsh-desktop-linux-0.2.3alpha2-1-x86_64.pkg.tar.zst", srcinfo)
        self.assertIn("\tpkgver = 0.2.3alpha2", srcinfo)
        self.assertNotIn("0.2.2rc5", pkgbuild + srcinfo)

    def test_same_version_with_a_different_checksum_is_refused(self):
        with self.assertRaisesRegex(ValueError, "refusing"):
            updater.update_files(self.root, "0.2.2rc5", SHA_ALPHA2)

    def test_older_release_does_not_move_the_pin(self):
        self.assertFalse(updater.update_files(self.root, "0.2.2rc4", SHA_OLD))
        self.assertIn("pkgver=0.2.2rc5", self.read()[0])

    def test_same_version_and_checksum_is_a_no_op(self):
        self.assertFalse(updater.update_files(self.root, "0.2.2rc5", SHA_OLD))


if __name__ == "__main__":
    unittest.main()

