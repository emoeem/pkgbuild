#!/usr/bin/env python3
"""Regression tests for the reF1nd stable-release updater."""
from __future__ import annotations

import importlib.util
import shutil
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "update_sing_box_ebpf", ROOT / "scripts/update-sing-box-ebpf.py"
)
assert SPEC and SPEC.loader
updater = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(updater)


class StableVersionTests(unittest.TestCase):
    def test_parses_stable_release(self):
        self.assertEqual(updater.version_tuple("1.14.3-reF1nd"), (1, 14, 3))

    def test_rejects_empty_or_testing_channel_metadata(self):
        for value in ("", "1.15.0-alpha.11-reF1nd", "1.14.3"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                updater.version_tuple(value)

    def test_checks_tag_sha_and_ebpf_capability(self):
        completed = type("Completed", (), {"stdout": "a" * 40 + "\trefs/tags/v1.14.3-reF1nd\n"})()
        with patch.object(updater.subprocess, "run", return_value=completed), \
             patch.object(updater, "fetch_text", side_effect=[
                 "//go:build with_ebpf && linux\nimport \"protocol/ebpf\"",
                 "type EBPFInboundOptions struct {}",
             ]), \
             patch.object(updater, "fetch_json", return_value=[{"name": "inbound.go"}]):
            self.assertEqual(updater.validate_release("1.14.3-reF1nd", "a" * 40), "v1.14.3-reF1nd")

    def test_rejects_tag_commit_mismatch(self):
        completed = type("Completed", (), {"stdout": "b" * 40 + "\trefs/tags/v1.14.3-reF1nd\n"})()
        with patch.object(updater.subprocess, "run", return_value=completed), self.assertRaises(ValueError):
            updater.validate_release("1.14.3-reF1nd", "a" * 40)

    def test_updates_pkgbuild_and_srcinfo_together_in_fixture(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "packages/sing-box-ebpf"
            package.mkdir(parents=True)
            shutil.copy2(ROOT / "packages/sing-box-ebpf/PKGBUILD", package / "PKGBUILD")
            shutil.copy2(ROOT / "packages/sing-box-ebpf/.SRCINFO", package / ".SRCINFO")
            current_tag, current_sha, _, current_version = updater.current_values(
                (package / "PKGBUILD").read_text()
            )
            major, minor, patch = updater.version_tuple(current_version + "-reF1nd")
            next_version = f"{major}.{minor}.{patch + 1}-reF1nd"
            next_tag = "v" + next_version
            next_pkgver = next_version.removesuffix("-reF1nd") + ".ref1nd"
            changed = updater.update_files(root, next_tag, "a" * 40, next_version)
            self.assertTrue(changed)
            pkgbuild = (package / "PKGBUILD").read_text()
            srcinfo = (package / ".SRCINFO").read_text()
            self.assertIn("_tag=" + next_tag, pkgbuild)
            self.assertIn("_commit=" + "a" * 40, pkgbuild)
            self.assertIn("pkgver=" + next_pkgver, pkgbuild)
            self.assertIn("pkgrel=1", pkgbuild)
            self.assertIn("pkgver = " + next_pkgver, srcinfo)
            self.assertIn("pkgrel = 1", srcinfo)
            self.assertIn("#tag=" + next_tag, srcinfo)

    def test_same_version_with_different_sha_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            package = root / "packages/sing-box-ebpf"
            package.mkdir(parents=True)
            shutil.copy2(ROOT / "packages/sing-box-ebpf/PKGBUILD", package / "PKGBUILD")
            shutil.copy2(ROOT / "packages/sing-box-ebpf/.SRCINFO", package / ".SRCINFO")
            pkgbuild_text = (package / "PKGBUILD").read_text()
            current_tag, current_sha, _, current_version = updater.current_values(pkgbuild_text)
            with self.assertRaisesRegex(ValueError, "differs"):
                updater.update_files(
                    root, current_tag, "a" * 40, current_version + "-reF1nd"
                )


if __name__ == "__main__":
    unittest.main()
