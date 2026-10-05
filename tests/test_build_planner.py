#!/usr/bin/env python3
"""Regression tests for scripts/build-planner.py.

The planner is the single decision point for "what will CI build and why", so
these tests pin the decision itself (changed / affected / rebuild / skipped)
and the explanation attached to it.
"""
import importlib.util
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("build_planner", ROOT / "scripts/build-planner.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class BuildPlannerTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "packages").mkdir()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.email", "t@example.invalid"], check=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.name", "test"], check=True)

    def tearDown(self):
        self.temp.cleanup()

    def add_package(self, name, provides=(), depends=(), makedepends=(), pkgver="1.0", pkgrel="1"):
        directory = self.root / "packages" / name
        directory.mkdir()
        lines = [
            f"pkgbase = {name}",
            "\tpkgdesc = test",
            f"\tpkgver = {pkgver}",
            f"\tpkgrel = {pkgrel}",
            "\tarch = x86_64",
            "",
            f"pkgname = {name}",
        ]
        lines += [f"\tprovides = {value}" for value in provides]
        lines += [f"\tdepends = {value}" for value in depends]
        lines += [f"\tmakedepends = {value}" for value in makedepends]
        (directory / ".SRCINFO").write_text("\n".join(lines) + "\n", encoding="utf-8")
        (directory / "PKGBUILD").write_text(f"pkgname={name}\npkgver={pkgver}\npkgrel={pkgrel}\n", encoding="utf-8")

    def commit(self, message):
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", message], check=True)
        return subprocess.check_output(["git", "-C", str(self.root), "rev-parse", "HEAD"], text=True).strip()

    def plan(self, selection, before, after="HEAD", **kwargs):
        return MODULE.build_plan(self.root, selection, before, after, **kwargs)

    def test_direct_change_selects_only_that_package(self):
        self.add_package("lib")
        self.add_package("app", depends=["lib"])
        before = self.commit("base")
        (self.root / "packages/lib/PKGBUILD").write_text("changed\n", encoding="utf-8")
        after = self.commit("change lib")
        plan = self.plan("changed", before, after)
        self.assertEqual(plan["changed"], ["lib"])
        self.assertEqual(plan["affected"], ["app"])
        self.assertEqual(sorted(plan["rebuild"]), ["app", "lib"])
        self.assertEqual(plan["skipped"], [])
        self.assertEqual(plan["counts"]["rebuild"], 2)
        self.assertTrue(any("provided by lib" in reason for reason in plan["reason"]["app"]))

    def test_unrelated_change_skips_everything(self):
        self.add_package("alpha")
        self.add_package("beta")
        before = self.commit("base")
        (self.root / "README.md").write_text("docs\n", encoding="utf-8")
        after = self.commit("docs")
        plan = self.plan("changed", before, after)
        self.assertEqual(plan["rebuild"], [])
        self.assertEqual(sorted(plan["skipped"]), ["alpha", "beta"])
        self.assertEqual(plan["counts"]["diff_files"], 1)

    def test_overlay_change_is_reported_as_overlay(self):
        self.add_package("alpha")
        before = self.commit("base")
        (self.root / "scripts/overlays").mkdir(parents=True)
        (self.root / "scripts/overlays/alpha.sh").write_text("x\n", encoding="utf-8")
        after = self.commit("overlay")
        plan = self.plan("changed", before, after)
        self.assertEqual(plan["overlay"], ["alpha"])
        self.assertEqual(plan["rebuild"], ["alpha"])
        self.assertIn("overlay: scripts/overlays/alpha.sh", plan["reason"]["alpha"])

    def test_infrastructure_change_rebuilds_everything(self):
        self.add_package("alpha")
        self.add_package("beta")
        before = self.commit("base")
        (self.root / "config").mkdir()
        (self.root / "config/flags.conf").write_text("x\n", encoding="utf-8")
        after = self.commit("config")
        plan = self.plan("changed", before, after)
        self.assertTrue(plan["infrastructure"]["changed"])
        self.assertEqual(sorted(plan["rebuild"]), ["alpha", "beta"])
        self.assertTrue(all("infrastructure" in plan["reason"][name][0] for name in plan["rebuild"]))

    def test_all_zero_before_rebuilds_everything_with_a_reason(self):
        self.add_package("alpha")
        after = self.commit("base")
        plan = self.plan("changed", "0" * 40, after)
        self.assertEqual(plan["rebuild"], ["alpha"])
        self.assertIn("all-zero before-SHA", plan["reason"]["alpha"][0])

    def test_repository_drift_is_detected_from_a_manifest(self):
        self.add_package("alpha", pkgver="2.5", pkgrel="3")
        self.add_package("beta", pkgver="1.0", pkgrel="1")
        after = self.commit("base")
        manifest = self.root / "manifest.txt"
        manifest.write_text("alpha\t1.0-1\tlibc.so.6\nbeta\t1.0-1\t\n", encoding="utf-8")
        plan = self.plan("changed", after, after, manifest_path=manifest)
        self.assertEqual(plan["rebuild"], ["alpha"])
        self.assertEqual(plan["repository"]["drift"], ["alpha"])
        self.assertIn("published 1.0-1 != source 2.5-3", plan["reason"]["alpha"][0])

    def test_manifest_epoch_is_normalised(self):
        self.add_package("alpha", pkgver="4.7.0", pkgrel="1")
        after = self.commit("base")
        manifest = self.root / "manifest.txt"
        manifest.write_text("alpha\t1:4.7.0-1\t\n", encoding="utf-8")
        plan = self.plan("changed", after, after, manifest_path=manifest)
        self.assertEqual(plan["repository"]["drift"], [])

    def test_estimated_duration_comes_from_the_timing_history(self):
        self.add_package("alpha")
        after = self.commit("base")
        timing = self.root / "timing.json"
        timing.write_text(
            json.dumps({"packages": [{"package": "alpha", "total_seconds": 802.5}]}),
            encoding="utf-8",
        )
        plan = self.plan("all", after, after, timing_db=timing)
        self.assertEqual(plan["estimated"]["source"], "timing-history")
        self.assertEqual(plan["estimated"]["seconds"], 802.5)

    def test_build_order_puts_providers_first(self):
        self.add_package("lib")
        self.add_package("app", depends=["lib"])
        after = self.commit("base")
        plan = self.plan("all", after, after)
        self.assertLess(plan["build_order"].index("lib"), plan["build_order"].index("app"))

    def test_unknown_package_is_rejected(self):
        self.add_package("alpha")
        after = self.commit("base")
        with self.assertRaises(SystemExit):
            self.plan("does-not-exist", after, after)

    def test_text_render_mentions_the_sections_from_the_spec(self):
        self.add_package("alpha")
        after = self.commit("base")
        text = MODULE.render_text(self.plan("all", after, after))
        for section in (
            "Build Plan",
            "Direct changes",
            "Dependency impact",
            "Infrastructure impact",
            "Skipped packages",
            "Total",
        ):
            self.assertIn(section, text)


if __name__ == "__main__":
    unittest.main()
