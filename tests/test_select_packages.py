#!/usr/bin/env python3
import importlib.util
import os
import shutil
import subprocess
import tempfile
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("select_packages", ROOT / "scripts/select-packages.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def git_environment():
    """Environment for the fixture repository's git commands.

    Git exports GIT_DIR/GIT_WORK_TREE/... to the hooks it runs, and a fixture
    command that inherits them ignores its own temporary directory: `git -C
    <fixture> init/add/commit/config` then acts on the repository the hook
    belongs to.  That is not hypothetical -- a pre-commit run of this suite set
    `core.bare` in the real checkout, overwrote its shared user.name/user.email
    and moved a branch onto fixture commits.  Dropping every GIT_* variable
    makes the commands below unable to reach anything but their own directory,
    however the suite was started.
    """
    return {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}


class SelectPackagesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "packages").mkdir()
        subprocess.run(["git", "init", "-q", str(self.root)], check=True, env=git_environment())
        subprocess.run(["git", "-C", str(self.root), "config", "user.email", "test@example.invalid"], check=True, env=git_environment())
        subprocess.run(["git", "-C", str(self.root), "config", "user.name", "test"], check=True, env=git_environment())

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

    def head(self, path):
        return subprocess.check_output(
            ["git", "-C", str(path), "rev-parse", "HEAD"], text=True, env=git_environment()
        ).strip()

    def install_lister(self):
        """Ship the real .rebuild-on parser into the fixture.

        Selection calls it as the single parser, so the tests below exercise
        the declaration format end to end instead of a second implementation.
        """
        scripts = self.root / "scripts"
        scripts.mkdir(exist_ok=True)
        shutil.copy(ROOT / "scripts/list-rebuild-triggers.sh", scripts / "list-rebuild-triggers.sh")

    def declare(self, package, *lines):
        (self.root / "packages" / package / ".rebuild-on").write_text(
            "\n".join(lines) + "\n", encoding="utf-8"
        )

    def commit(self, message):
        subprocess.run(["git", "-C", str(self.root), "add", "."], check=True, env=git_environment())
        subprocess.run(["git", "-C", str(self.root), "commit", "-qm", message], check=True, env=git_environment())
        return subprocess.check_output(
            ["git", "-C", str(self.root), "rev-parse", "HEAD"], text=True, env=git_environment()
        ).strip()

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

    def test_build_script_change_does_not_rebuild_everything(self):
        self.add_package("foo")
        self.add_package("bar")
        before = self.commit("base")
        (self.root / "scripts").mkdir()
        (self.root / "scripts/build-in-arch.sh").write_text("changed\n", encoding="utf-8")
        after = self.commit("build infrastructure")
        self.assertEqual(self.select(before, after), [])

    def test_zero_before_sha_rebuilds_everything(self):
        self.add_package("foo")
        self.add_package("bar")
        after = self.commit("base")
        self.assertEqual(self.select("0" * 40, after), ["bar", "foo"])

    def test_empty_before_rebuilds_everything(self):
        self.add_package("foo")
        after = self.commit("base")
        self.assertEqual(self.select("", after), ["foo"])

    def test_config_change_rebuilds_everything(self):
        self.add_package("foo")
        self.add_package("bar")
        before = self.commit("base")
        (self.root / "config").mkdir()
        (self.root / "config/emo-native-flags.conf").write_text("changed\n", encoding="utf-8")
        after = self.commit("build flags")
        self.assertEqual(self.select(before, after), ["bar", "foo"])

    def test_update_source_registry_does_not_rebuild_everything(self):
        self.add_package("foo")
        self.add_package("bar")
        before = self.commit("base")
        (self.root / "config").mkdir()
        (self.root / "config/package-updates.txt").write_text("foo manual\n", encoding="utf-8")
        after = self.commit("update source registry")
        self.assertEqual(self.select(before, after), [])

    def test_rebuild_on_package_edge_propagates(self):
        self.install_lister()
        self.add_package("toolchain")
        self.add_package("consumer")
        self.declare("consumer", "package toolchain")
        before = self.commit("base")
        (self.root / "packages/toolchain/PKGBUILD").write_text("changed\n", encoding="utf-8")
        after = self.commit("change toolchain")
        self.assertEqual(self.select(before, after), ["consumer", "toolchain"])

    def test_rebuild_on_soname_provider_propagates(self):
        self.install_lister()
        self.add_package("libshine")
        self.add_package("ffmpeg-full")
        self.declare("ffmpeg-full", "soname libshine.so.3 libshine")
        before = self.commit("base")
        (self.root / "packages/libshine/PKGBUILD").write_text("changed\n", encoding="utf-8")
        after = self.commit("change libshine")
        self.assertEqual(self.select(before, after), ["ffmpeg-full", "libshine"])

    def test_rebuild_on_external_provider_does_not_select_anything(self):
        self.install_lister()
        self.add_package("ffmpeg-full")
        self.add_package("other")
        self.declare("ffmpeg-full", "soname libshine.so.3 shine")
        before = self.commit("base")
        (self.root / "packages/other/PKGBUILD").write_text("changed\n", encoding="utf-8")
        after = self.commit("change other")
        self.assertEqual(self.select(before, after), ["other"])

    def test_malformed_rebuild_on_fails_selection(self):
        self.install_lister()
        self.add_package("foo")
        self.declare("foo", "soname libonly-version.so.1")
        before = self.commit("base")
        (self.root / "packages/foo/PKGBUILD").write_text("changed\n", encoding="utf-8")
        after = self.commit("change foo")
        # pkgbuild_lib raises SourceInfoError (a RuntimeError), not SystemExit.
        with self.assertRaises((RuntimeError, SystemExit)):
            self.select(before, after)

    def test_fixture_git_ignores_an_inherited_git_directory(self):
        """Regression: git hands GIT_DIR/GIT_WORK_TREE to the hooks it runs.

        Without git_environment() the fixture below would init, configure and
        commit into whatever repository those variables point at, which is how a
        pre-commit run of this suite reached the developer's real checkout.
        """
        with tempfile.TemporaryDirectory() as decoy_name:
            decoy = Path(decoy_name)
            environment = git_environment()
            subprocess.run(["git", "init", "-q", str(decoy)], check=True, env=environment)
            (decoy / "file").write_text("decoy\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(decoy), "add", "."], check=True, env=environment)
            subprocess.run(
                [
                    "git",
                    "-C",
                    str(decoy),
                    "-c",
                    "user.email=test@example.invalid",
                    "-c",
                    "user.name=test",
                    "commit",
                    "-qm",
                    "decoy",
                ],
                check=True,
                env=environment,
            )
            untouched = self.head(decoy)

            os.environ["GIT_DIR"] = str(decoy / ".git")
            os.environ["GIT_WORK_TREE"] = str(decoy)
            try:
                self.add_package("foo")
                fixture_revision = self.commit("base")
            finally:
                del os.environ["GIT_DIR"]
                del os.environ["GIT_WORK_TREE"]

            self.assertNotEqual(fixture_revision, untouched)
            self.assertEqual(self.head(decoy), untouched)


if __name__ == "__main__":
    unittest.main()
