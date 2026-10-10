#!/usr/bin/env python3
"""Unit tests for scripts/check-package-manifests.py.

Each test builds a throwaway repository in a temporary directory and runs the
linter as a subprocess, so the assertions cover the real CLI contract (exit
status, printed ERROR lines, the final SUMMARY line) rather than internals.

The last test points the linter at *this* checkout: it is the regression anchor
that fails if a real package loses its update source or its metadata drifts.
"""

import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LINTER = ROOT / "scripts" / "check-package-manifests.py"


def git_environment():
    """Environment for the linter and the fixture repository's git commands.

    Git exports GIT_DIR/GIT_WORK_TREE/... to the hooks it runs, and a subprocess
    that inherits them looks at the repository the hook belongs to instead of
    the fixture below it: a pre-commit run reported the developer's real checkout
    as "not tracked by git" and failed three cases that pass on their own.
    Dropping every GIT_* variable keeps the linter and `git` on the fixture,
    however the suite was started; the config files are pinned so a developer's
    own git configuration cannot change the outcome.
    """
    environment = {
        key: value for key, value in os.environ.items() if not key.startswith("GIT_")
    }
    environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
    environment["GIT_CONFIG_SYSTEM"] = "/dev/null"
    return environment
COMMIT = "0" * 40

PKGBUILD = """pkgname=%(name)s
pkgver=1.0
pkgrel=1
pkgdesc="A test package"
url="https://example.com/%(name)s"
license=('MIT')
source=('https://example.com/%(name)s.tar.gz')
sha256sums=('deadbeef')
"""

SRCINFO = """pkgbase = %(name)s
\tpkgdesc = A test package
\tpkgver = 1.0
\tpkgrel = 1
\turl = https://example.com/%(name)s
\tlicense = MIT
\tsource = https://example.com/%(name)s.tar.gz
\tsha256sums = deadbeef

pkgname = %(name)s
"""


class ManifestLintTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="pkgbuild-manifests-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        (self.tmp / "packages").mkdir()
        (self.tmp / "config").mkdir()

    # -- helpers ---------------------------------------------------------

    def add_package(self, name, srcinfo=None, pkgbuild=None, aur=True):
        directory = self.tmp / "packages" / name
        directory.mkdir()
        (directory / "PKGBUILD").write_text(
            PKGBUILD % {"name": name} if pkgbuild is None else pkgbuild,
            encoding="utf-8",
        )
        (directory / ".SRCINFO").write_text(
            SRCINFO % {"name": name} if srcinfo is None else srcinfo,
            encoding="utf-8",
        )
        if aur:
            (directory / ".aur-url").write_text(
                f"https://aur.archlinux.org/{name}.git\n", encoding="utf-8"
            )
            (directory / ".aur-commit").write_text(COMMIT + "\n", encoding="utf-8")
        return directory

    def write_registry(self, text):
        (self.tmp / "config" / "package-updates.txt").write_text(
            text, encoding="utf-8"
        )

    def lint(self, root=None):
        result = subprocess.run(
            [sys.executable, str(LINTER), "--root", str(root or self.tmp)],
            capture_output=True,
            text=True,
            check=False,
            env=git_environment(),
        )
        return result.returncode, result.stdout + result.stderr

    def assert_error(self, code, output, fragment):
        self.assertEqual(code, 1, f"expected failure, got:\n{output}")
        self.assertIn("ERROR", output)
        self.assertIn(fragment, output)
        self.assertRegex(output, r"SUMMARY packages=\d+ errors=[1-9]")

    # -- update-source contract ------------------------------------------

    def test_clean_tree_passes(self):
        self.add_package("alpha")
        self.add_package("beta")
        code, output = self.lint()
        self.assertEqual(code, 0, output)
        self.assertIn("SUMMARY packages=2 errors=0", output)

    def test_registry_entry_satisfies_non_aur_package(self):
        self.add_package("manual-pkg", aur=False)
        self.write_registry("manual-pkg manual nothing updates this by design\n")
        code, output = self.lint()
        self.assertEqual(code, 0, output)

    def test_missing_update_source_fails(self):
        self.add_package("orphan", aur=False)
        code, output = self.lint()
        self.assert_error(code, output, "no update source declared")

    def test_double_update_source_fails(self):
        self.add_package("both")
        self.write_registry("both manual also listed here\n")
        code, output = self.lint()
        self.assert_error(code, output, "declares an update source twice")

    def test_aur_url_without_commit_fails(self):
        directory = self.add_package("nocommit")
        (directory / ".aur-commit").unlink()
        code, output = self.lint()
        self.assert_error(code, output, ".aur-url without .aur-commit")

    def test_short_aur_commit_fails(self):
        directory = self.add_package("shortcommit")
        (directory / ".aur-commit").write_text("abc123\n", encoding="utf-8")
        code, output = self.lint()
        self.assert_error(code, output, "40-character git commit")

    def test_non_aur_url_fails(self):
        directory = self.add_package("elsewhere")
        (directory / ".aur-url").write_text(
            "https://gitlab.com/someone/elsewhere\n", encoding="utf-8"
        )
        code, output = self.lint()
        self.assert_error(code, output, "is not an https://aur.archlinux.org/")

    def test_two_line_aur_url_fails(self):
        directory = self.add_package("twolines")
        (directory / ".aur-url").write_text(
            "https://aur.archlinux.org/twolines.git\n"
            "https://aur.archlinux.org/other.git\n",
            encoding="utf-8",
        )
        code, output = self.lint()
        self.assert_error(code, output, "exactly one URL")

    def test_renamed_aur_package_is_only_a_note(self):
        self.add_package("alias-pkg")
        (self.tmp / "packages" / "alias-pkg" / ".aur-url").write_text(
            "https://aur.archlinux.org/upstream-name.git\n", encoding="utf-8"
        )
        code, output = self.lint()
        self.assertEqual(code, 0, output)
        self.assertIn("NOTE", output)

    # -- registry validation ---------------------------------------------

    def test_registry_entry_for_unknown_package_fails(self):
        self.add_package("alpha")
        self.write_registry("ghost manual there is no such directory\n")
        code, output = self.lint()
        self.assert_error(code, output, "no such package directory packages/ghost")

    def test_registry_bad_line_fails(self):
        self.add_package("alpha")
        self.write_registry("alpha\n")
        code, output = self.lint()
        self.assert_error(code, output, "expected `<package> <kind> <detail>`")

    def test_registry_unknown_kind_fails(self):
        self.add_package("alpha")
        self.write_registry("alpha telepathy reads my mind\n")
        code, output = self.lint()
        self.assert_error(code, output, "unknown kind 'telepathy'")

    def test_registry_duplicate_fails(self):
        self.add_package("alpha")
        self.write_registry("alpha manual first\nalpha manual second\n")
        code, output = self.lint()
        self.assert_error(code, output, "duplicate entry for alpha")

    def test_registry_workflow_must_exist_without_git(self):
        self.add_package("alpha")
        self.write_registry("alpha workflow .github/workflows/nope.yml\n")
        code, output = self.lint()
        self.assert_error(code, output, "names missing file")

    def test_registry_workflow_must_be_tracked_by_git(self):
        self.add_package("alpha", aur=False)
        (self.tmp / ".github" / "workflows").mkdir(parents=True)
        (self.tmp / ".github" / "workflows" / "real.yml").write_text(
            "on: push\n", encoding="utf-8"
        )
        self.write_registry("alpha workflow .github/workflows/real.yml\n")
        self.git("init", "-q")
        self.git("add", "packages", "config")
        code, output = self.lint()
        self.assert_error(code, output, "which is not tracked by git")

        self.git("add", ".github")
        code, output = self.lint()
        self.assertEqual(code, 0, output)

    def git(self, *args, stdin=None):
        result = subprocess.run(
            ["git", "-C", str(self.tmp), *args],
            capture_output=True,
            text=True,
            check=True,
            input=stdin,
            env=git_environment(),
        )
        return result.stdout

    # -- metadata contract -----------------------------------------------

    def test_pkgbase_mismatch_fails(self):
        self.add_package(
            "renamed", srcinfo=SRCINFO % {"name": "something-else"}
        )
        code, output = self.lint()
        self.assert_error(code, output, "pkgbase is 'something-else'")

    def test_pkgver_with_dash_fails(self):
        self.add_package(
            "badver", srcinfo=SRCINFO.replace("pkgver = 1.0", "pkgver = 1.0-1")
        )
        code, output = self.lint()
        self.assert_error(code, output, "pkgver '1.0-1'")

    def test_pkgrel_non_numeric_fails(self):
        self.add_package(
            "badrel", srcinfo=SRCINFO.replace("pkgrel = 1", "pkgrel = one")
        )
        code, output = self.lint()
        self.assert_error(code, output, "pkgrel 'one' is not a number")

    def test_missing_description_fails(self):
        self.add_package(
            "nodesc", srcinfo=SRCINFO.replace("\tpkgdesc = A test package\n", "")
        )
        code, output = self.lint()
        self.assert_error(code, output, "pkgdesc is missing or empty")

    def test_missing_license_fails(self):
        self.add_package(
            "nolicense", srcinfo=SRCINFO.replace("\tlicense = MIT\n", "")
        )
        code, output = self.lint()
        self.assert_error(code, output, "no license declared")

    def test_checksum_parity_fails(self):
        broken = SRCINFO.replace(
            "\tsha256sums = deadbeef",
            "\tsource = https://example.com/extra.tar.gz\n\tsha256sums = deadbeef",
        )
        self.add_package("lopsided", srcinfo=broken)
        code, output = self.lint()
        self.assert_error(
            code, output, "sha256sums has 1 entries for 2 source entries"
        )

    def test_empty_srcinfo_fails(self):
        self.add_package("empty", srcinfo="")
        code, output = self.lint()
        self.assert_error(code, output, "empty or unparseable")

    def test_missing_pkgbuild_fails(self):
        directory = self.add_package("nopkgbuild")
        (directory / "PKGBUILD").unlink()
        code, output = self.lint()
        self.assert_error(code, output, "PKGBUILD is missing")

    def test_unparseable_package_name_fails(self):
        self.add_package("bad name")
        code, output = self.lint()
        self.assert_error(code, output, "not a valid package name")

    def test_no_packages_at_all_fails(self):
        code, output = self.lint()
        self.assert_error(code, output, "no package directories containing PKGBUILD")

    def test_committed_submodule_fails(self):
        self.add_package("alpha")
        (self.tmp / "packages" / "vendored").mkdir()
        self.git("init", "-q")
        self.git("add", "packages", "config")
        # update-index refuses an all-zero object name, so mint a real one.
        blob = self.git("hash-object", "-w", "--stdin", stdin="vendored\n").strip()
        self.git(
            "update-index",
            "--add",
            "--cacheinfo",
            f"160000,{blob},packages/vendored",
        )
        code, output = self.lint()
        self.assert_error(code, output, "committed gitlink")

    # -- .rebuild-on declarations ----------------------------------------

    def add_rebuild_on(self, name, text):
        directory = self.tmp / "packages" / name
        if not directory.is_dir():
            directory = self.add_package(name)
        (directory / ".rebuild-on").write_text(text, encoding="utf-8")
        return directory

    def test_rebuild_on_soname_declaration_passes(self):
        self.add_rebuild_on(
            "linked-outside",
            "# a library from archlinuxcn\nsoname libshine.so.3 shine\n",
        )
        code, output = self.lint()
        self.assertEqual(code, 0, output)
        self.assertIn("1 declared external soname(s)", output)

    def test_rebuild_on_package_trigger_needs_a_real_dependency(self):
        self.add_rebuild_on("manual-dep", "package linuxqq\n")
        code, output = self.lint()
        self.assert_error(code, output, "is not one of this package's")

    def test_rebuild_on_package_trigger_with_dependency_passes(self):
        self.add_package(
            "aur-dep", srcinfo=SRCINFO % {"name": "aur-dep"} + "\tdepends = linuxqq\n"
        )
        self.add_rebuild_on("aur-dep", "package linuxqq\n")
        code, output = self.lint()
        self.assertEqual(code, 0, output)

    def test_rebuild_on_version_constraint_is_ignored(self):
        self.add_package(
            "pinned-dep",
            srcinfo=SRCINFO % {"name": "pinned-dep"} + "\tdepends = linuxqq>=3.0\n",
        )
        self.add_rebuild_on("pinned-dep", "package linuxqq\n")
        code, output = self.lint()
        self.assertEqual(code, 0, output)

    def test_rebuild_on_unknown_kind_fails(self):
        self.add_rebuild_on("mystery", "container some/image:latest\n")
        code, output = self.lint()
        self.assert_error(code, output, "unknown trigger 'container'")

    def test_rebuild_on_bad_soname_fails(self):
        self.add_rebuild_on("bad-soname", "soname libshine shine\n")
        code, output = self.lint()
        self.assert_error(code, output, "is not a shared library name")

    def test_rebuild_on_bad_provider_fails(self):
        self.add_rebuild_on("bad-provider", "soname libshine.so.3 bad/name\n")
        code, output = self.lint()
        self.assert_error(code, output, "is not a valid package name")

    def test_rebuild_on_short_soname_line_fails(self):
        self.add_rebuild_on("short-soname", "soname libshine.so.3\n")
        code, output = self.lint()
        self.assert_error(code, output, "expected `<soname> <provider>`")

    def test_rebuild_on_short_package_line_fails(self):
        self.add_rebuild_on("short-package", "package\n")
        code, output = self.lint()
        self.assert_error(code, output, "expected `<name>` after `package`")

    def test_rebuild_on_duplicate_soname_fails(self):
        self.add_rebuild_on(
            "double",
            "soname libshine.so.3 shine\nsoname libshine.so.3 other\n",
        )
        code, output = self.lint()
        self.assert_error(code, output, "duplicate soname trigger")

    def test_rebuild_on_without_triggers_fails(self):
        self.add_rebuild_on("empty-triggers", "# nothing but a comment\n")
        code, output = self.lint()
        self.assert_error(code, output, "declares no triggers")

    # -- the real tree ---------------------------------------------------

    def test_real_repository_is_clean(self):
        self.assertTrue(LINTER.is_file(), f"{LINTER} is missing")
        code, output = self.lint(root=ROOT)
        self.assertEqual(code, 0, output)
        self.assertIn("errors=0", output)
        expected = len(list((ROOT / "packages").glob("*/PKGBUILD")))
        self.assertIn(f"SUMMARY packages={expected} errors=0", output)


if __name__ == "__main__":
    unittest.main()
