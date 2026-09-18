#!/usr/bin/env python3
import importlib.util
import subprocess
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("select_packages", ROOT / "scripts/select-packages.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)

class SelectPackagesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "packages").mkdir()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.email", "test@example.invalid"], check=True)
        subprocess.run(["git", "-C", str(self.root), "config", "user.name", "test"], check=True)

    def tearDown(self):
        self.temp.cleanup()

    def add_package(self, name, provides=(), depends=(), makedepends=(), checkdepends=()):
        directory = self.root / "packages" / name
        directory.mkdir()
        lines = [f"pkgbase = {name}", f"\tpkgdesc = test {name}", "\tarch = x86_64", "", f"pkgname = {name}"]
        lines += [f"\tprovides = {value}" for value in provides]
        lines += [f"\tdepends = {value}" for value in depends]
        lines += [f"\tmakedepends = {value}" for value in makedepends]
        lines += [f"\tcheckdepends = {value}" for value in checkdepends]
        (directory / ".SRCINFO").write_text("\n".join(lines) + "\n", encoding="utf-8")
        (directory / "PKGBUILD").write_text("pkgname=test\n", encoding="utf-8")

    def commit(self, message):
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True)
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", message], check=True)
        return subprocess.check_output(["git", "-C", str(self.root), "rev-parse", "HEAD"], text=True).strip()

    def select(self, before, after):
        return MODULE.select(self.root, "changed", before, after)

    def test_virtual_provide_propagates(self):
        self.add_package("ffmpeg-full", provides=["ffmpeg"])
        self.add_package("mpv-emo", depends=["ffmpeg"])
        before = self.commit("base")
        (self.root / "packages/ffmpeg-full/PKGBUILD").write_text("changed\n", encoding="utf-8")
        after = self.commit("change ffmpeg")
        self.assertEqual(self.select(before, after), ["ffmpeg-full", "mpv-emo"])

    def test_transitive_dependencies_propagate(self):
        self.add_package("lib-a", provides=["virtual-a"])
        self.add_package("lib-b", depends=["virtual-a"], provides=["virtual-b"])
        self.add_package("app", depends=["virtual-b"])
        before = self.commit("base")
        (self.root / "packages/lib-a/PKGBUILD").write_text("changed\n", encoding="utf-8")
        after = self.commit("change lib-a")
        self.assertEqual(self.select(before, after), ["app", "lib-a", "lib-b"])

    def test_build_and_check_dependencies_propagate(self):
        self.add_package("toolchain", provides=["virtual-tool"])
        self.add_package("consumer-make", makedepends=["virtual-tool"])
        self.add_package("consumer-check", checkdepends=["virtual-tool"])
        before = self.commit("base")
        (self.root / "packages/toolchain/PKGBUILD").write_text("changed\n", encoding="utf-8")
        after = self.commit("change toolchain")
        self.assertEqual(self.select(before, after), ["consumer-check", "consumer-make", "toolchain"])

    def test_overlay_selects_matching_package(self):
        self.add_package("ffmpeg-full")
        self.add_package("mpv-emo")
        before = self.commit("base")
        (self.root / "scripts/overlays").mkdir(parents=True)
        (self.root / "scripts/overlays/ffmpeg-full.sh").write_text("changed\n", encoding="utf-8")
        after = self.commit("change overlay")
        self.assertEqual(self.select(before, after), ["ffmpeg-full"])

    def test_unrelated_document_does_not_build(self):
        self.add_package("foo")
        before = self.commit("base")
        (self.root / "README.md").write_text("docs\n", encoding="utf-8")
        after = self.commit("docs")
        self.assertEqual(self.select(before, after), [])

    def test_build_script_change_rebuilds_everything(self):
        self.add_package("foo")
        self.add_package("bar")
        before = self.commit("base")
        (self.root / "scripts").mkdir()
        (self.root / "scripts/build-in-arch.sh").write_text("changed\n", encoding="utf-8")
        after = self.commit("build infrastructure")
        self.assertEqual(self.select(before, after), ["bar", "foo"])

if __name__ == "__main__":
    unittest.main()
