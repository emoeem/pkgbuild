#!/usr/bin/env python3
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
ROUTE = ROOT / "scripts" / "resolve-update-route.py"


class UpdateRouteTests(unittest.TestCase):
    def route(self, package):
        return subprocess.run(
            [sys.executable, str(ROUTE), "--root", str(ROOT), "--package", package],
            text=True,
            capture_output=True,
            check=False,
        )

    def test_vendored_dependencies_route_to_owner_package(self):
        for name in ("lensfun-master", "whisper-cpp"):
            with self.subTest(name=name):
                result = self.route(name)
                self.assertEqual(0, result.returncode, result.stderr)
                self.assertEqual("vendored\tffmpeg-full", result.stdout.strip())

    def test_workflow_package_routes_to_own_workflow(self):
        result = self.route("dsh-desktop-linux")
        self.assertEqual(0, result.returncode)
        self.assertEqual(
            "workflow\t.github/workflows/dsh-desktop-linux-update.yml",
            result.stdout.strip(),
        )

    def test_aur_package_routes_to_sync_not_vendored_owner(self):
        result = self.route("quirc")
        self.assertEqual(0, result.returncode)
        self.assertEqual("aur\tquirc", result.stdout.strip())

    def test_manual_and_unknown_routes_are_distinct(self):
        manual = self.route("trae-cn-appimage")
        self.assertEqual(0, manual.returncode)
        self.assertEqual("manual", manual.stdout.split("\t", 1)[0])
        unknown = self.route("does-not-exist")
        self.assertEqual(3, unknown.returncode)
        self.assertEqual("unknown", unknown.stdout.strip())


if __name__ == "__main__":
    unittest.main()
