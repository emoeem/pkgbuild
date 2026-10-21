#!/usr/bin/env python3
"""Regression tests for the Filee release updater."""
from __future__ import annotations

import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("update_filee", ROOT / "scripts/update-filee.py")
assert SPEC and SPEC.loader
updater = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(updater)


class VersionTests(unittest.TestCase):
    def test_parses_release_version(self):
        self.assertEqual(updater.version_tuple("1.12.0"), (1, 12, 0))
        self.assertEqual(updater.version_tuple("v1.12.0"), (1, 12, 0))

    def test_rejects_non_release_versions(self):
        for value in ("", "1.12", "v1.12.0-rc1", "1.12.0.1"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                updater.version_tuple(value)


class ChecksumTests(unittest.TestCase):
    NAME = "Filee-1.12.0-linux-x64.tar.gz"
    SUM = "a" * 64

    def test_reads_gnu_and_binary_marker_sums(self):
        for line in (f"{self.SUM}  {self.NAME}", f"{self.SUM} *{self.NAME}"):
            with self.subTest(line=line):
                self.assertEqual(self.SUM, updater.parse_sums(line, self.NAME))

    def test_missing_or_malformed_sums_are_rejected(self):
        with self.assertRaises(ValueError):
            updater.parse_sums(f"{self.SUM}  other.tar.gz", self.NAME)
        with self.assertRaises(ValueError):
            updater.parse_sums(f"not-a-hash  {self.NAME}", self.NAME)

    def test_asset_digest_must_agree_with_sums(self):
        asset = {"name": self.NAME, "digest": f"sha256:{self.SUM}"}
        self.assertEqual(self.SUM, updater.expected_checksum(asset, f"{self.SUM}  {self.NAME}\n"))
        asset["digest"] = "sha256:" + "b" * 64
        with self.assertRaisesRegex(ValueError, "does not match"):
            updater.expected_checksum(asset, f"{self.SUM}  {self.NAME}\n")

    def test_missing_digest_falls_back_to_the_sums_file(self):
        asset = {"name": self.NAME}
        self.assertEqual(self.SUM, updater.expected_checksum(asset, f"{self.SUM}  {self.NAME}\n"))


class ReleaseAssetTests(unittest.TestCase):
    def release(self, **overrides):
        tarball = {"name": updater.TARBALL_NAME.format(version="1.13.0"), "state": "uploaded"}
        sums = {"name": updater.SUMS_NAME.format(version="1.13.0"), "state": "uploaded"}
        tarball.update(overrides)
        return {"assets": [tarball, sums]}

    def test_selects_the_linux_x64_tarball_and_sums(self):
        tarball, sums = updater.release_assets(self.release(), "1.13.0")
        self.assertEqual(updater.TARBALL_NAME.format(version="1.13.0"), tarball["name"])
        self.assertEqual(updater.SUMS_NAME.format(version="1.13.0"), sums["name"])

    def test_missing_assets_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "does not publish"):
            updater.release_assets({"assets": []}, "1.13.0")

    def test_unuploaded_assets_are_rejected(self):
        with self.assertRaisesRegex(ValueError, "not uploaded"):
            updater.release_assets(self.release(state="new"), "1.13.0")


class UpdateFileTests(unittest.TestCase):
    def copy_package(self, root: Path) -> Path:
        package = root / "packages/filee-bin"
        package.mkdir(parents=True)
        shutil.copy2(ROOT / "packages/filee-bin/PKGBUILD", package / "PKGBUILD")
        shutil.copy2(ROOT / "packages/filee-bin/.SRCINFO", package / ".SRCINFO")
        return package

    def next_version(self, package: Path) -> str:
        """A version strictly newer than whatever is pinned right now.

        The updater refuses downgrades, so a hardcoded version in this fixture
        turns the test red the moment the automated filee update pins something
        higher (it did: the pinned 2.0.0 made the old 1.13.0 fixture fail with
        "Filee 1.13.0 is older than the pinned 2.0.0; no change").
        """
        pinned, _, _ = updater.current_values((package / "PKGBUILD").read_text())
        head, _, tail = pinned.rpartition(".")
        return f"{head}.{int(tail) + 1}"

    def test_bumps_pkgver_pkgrel_and_checksum_in_both_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = self.copy_package(root)
            checksum = "a" * 64
            candidate = self.next_version(package)
            self.assertTrue(updater.update_files(root, candidate, checksum))
            pkgbuild = (package / "PKGBUILD").read_text(encoding="utf-8")
            srcinfo = (package / ".SRCINFO").read_text(encoding="utf-8")
            self.assertIn(f"pkgver={candidate}", pkgbuild)
            self.assertIn("pkgrel=1", pkgbuild)
            self.assertIn(f"sha256sums=('{checksum}')", pkgbuild)
            self.assertIn(f"pkgver = {candidate}", srcinfo)
            self.assertIn("pkgrel = 1", srcinfo)
            self.assertIn(
                "source = https://github.com/KnifeLemon/Filee/releases/download/"
                f"v{candidate}/Filee-{candidate}-linux-x64.tar.gz",
                srcinfo,
            )
            self.assertIn(f"sha256sums = {checksum}", srcinfo)

    def test_same_version_with_a_different_checksum_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = self.copy_package(root)
            pkgver, _, _ = updater.current_values((package / "PKGBUILD").read_text())
            with self.assertRaisesRegex(ValueError, "refusing to silently repin"):
                updater.update_files(root, pkgver, "a" * 64)

    def test_older_release_is_not_a_downgrade(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = self.copy_package(root)
            before = (package / "PKGBUILD").read_bytes()
            self.assertFalse(updater.update_files(root, "1.11.9", "a" * 64))
            self.assertEqual(before, (package / "PKGBUILD").read_bytes())

    def test_current_files_need_no_update(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = self.copy_package(root)
            pkgver, _, checksum = updater.current_values((package / "PKGBUILD").read_text())
            self.assertFalse(updater.update_files(root, pkgver, checksum))


if __name__ == "__main__":
    unittest.main()
