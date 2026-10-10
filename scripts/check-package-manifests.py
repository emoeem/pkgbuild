#!/usr/bin/env python3
"""Static policy gate over packages/*/: the manifest half of CI.

Ported from archlinuxcn's repo-level `pre-commit` gate, which validates every
package manifest before a build is ever attempted.  The point of *that* gate is
that it is fast and needs nothing but Python: it runs on the bare runner, before
a builder image is pulled and before makepkg exists.  This script keeps the same
constraint -- standard library only, no container, no makepkg.

It is complementary to the two checkers that already exist:

  scripts/audit-packages.sh   needs makepkg; checks .SRCINFO freshness against
                              PKGBUILD, provider/conflict consistency.
  scripts/check-package.sh    needs makepkg; syntax + local sources + metadata.

Neither can run without the builder image.  This one can, so a package that
would fail those checks fails here first, for free.

Two contracts are enforced.

1. Every packages/<name> declares its update source, exactly once.

   AUR-managed packages declare it with .aur-url (consumed by
   scripts/sync-aur-packages.sh, which also rewrites .aur-commit).  Every other
   package must have an explicit entry in config/package-updates.txt naming an
   automated updater (`workflow <path>`) or stating that there is none
   (`manual <reason>`).  This is the local translation of lilac's rule that a
   package must either carry `update_on` or say `managed: false`: nothing may
   be silently un-updatable, because an un-updatable package is only noticed
   when its published binary goes stale.

2. The committed metadata is self-consistent.

   pkgbase matches the directory name, pkgver/pkgrel are well formed, pkgdesc /
   url / license are present, and every checksum array has exactly one entry per
   source entry.  These are the mistakes that otherwise surface as a build
   failure minutes into a container job.

3. packages/<name>/.rebuild-on, when present, is well formed.

   The file declares the build outputs outside the configured repositories that
   must force a rebuild of this package when they change -- the same role as
   lilac's per-package `update_on` list, restricted to what the repository can
   actually observe:

     soname  <soname> <provider>   a library this package links against that
                                   comes from a repository the CI containers do
                                   not configure (consumed by
                                   scripts/check-repository-sonames.sh, which
                                   also checks the declaration against the
                                   published artifact)
     package <name>                an external dependency whose version drift
                                   must rebuild it (consumed by
                                   scripts/check-dependency-drift.sh)

   A malformed declaration is worse than none: it either widens an exemption or
   hides a real staleness report, so every line is checked here -- the file must
   parse, sonames must look like sonames, providers and package names must be
   valid, there may be no duplicates, and a `package` trigger must be one of the
   package's own depends/makedepends/checkdepends.

Exit status is 0 when clean and 1 when any error was found.  The last line is
always `SUMMARY packages=<n> errors=<n>`, so a failing CI step stays greppable.
"""

import argparse
import re
import subprocess
import sys
from pathlib import Path

PACKAGE_NAME = re.compile(r"^[A-Za-z0-9@._+-]+$")
PKGREL = re.compile(r"^[0-9]+(\.[0-9]+)?$")
AUR_URL = re.compile(r"^https://aur\.archlinux\.org/(?P<name>[A-Za-z0-9@._+-]+)\.git$")
GIT_COMMIT = re.compile(r"^[0-9a-f]{40}$")
REGISTRY_KINDS = ("manual", "workflow")
REGISTRY_PATH = Path("config/package-updates.txt")
REBUILD_ON_KINDS = ("soname", "package")
SONAME = re.compile(r"^[A-Za-z0-9+._-]+\.so(\.[0-9]+)*$")
VERSION_CONSTRAINT = re.compile(r"[<>=].*$")


def parse_srcinfo(path):
    """Return .SRCINFO as a list of sections, each a mapping of key -> values.

    A section starts at a column-zero `key = value` line (pkgbase, then one per
    pkgname) and holds the tab-indented fields that follow it.  Sources and
    checksums are per-section, which is what the parity check below needs.
    """
    sections = []
    current = None
    for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not raw.strip():
            current = None
            continue
        if raw.startswith("\t"):
            key, separator, value = raw[1:].partition(" = ")
            if current is not None and separator:
                current.setdefault(key.strip(), []).append(value.strip())
            continue
        key, _, value = raw.partition(" = ")
        current = {key.strip(): [value.strip()]}
        sections.append(current)
    return sections


def load_registry(path):
    """Parse config/package-updates.txt into {package: (kind, detail, line)}."""
    entries = {}
    errors = []
    if not path.is_file():
        return entries, errors
    for lineno, raw in enumerate(
        path.read_text(encoding="utf-8", errors="replace").splitlines(), start=1
    ):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 2)
        if len(parts) < 3:
            errors.append(
                f"{path}:{lineno}: expected `<package> <kind> <detail>`"
            )
            continue
        package, kind, detail = parts
        if kind not in REGISTRY_KINDS:
            errors.append(
                f"{path}:{lineno}: unknown kind '{kind}' "
                f"(expected one of: {', '.join(REGISTRY_KINDS)})"
            )
            continue
        if package in entries:
            errors.append(f"{path}:{lineno}: duplicate entry for {package}")
            continue
        entries[package] = (kind, detail, lineno)
    return entries, errors


def tracked_files(root):
    """Return the set of git-tracked paths, or None when git is unavailable."""
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    return set(result.stdout.splitlines())


def tracked_gitlinks(root):
    """Return tracked gitlink paths (committed submodules), or None.

    Submodules under packages/ are a packaging hazard: the build checks out the
    commit, not the submodule contents, so the package directory can look
    complete locally and be empty in CI.
    """
    try:
        result = subprocess.run(
            ["git", "-C", str(root), "ls-files", "-s", "--", "packages"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    if result.returncode != 0:
        return None
    return [
        line.split("\t", 1)[1]
        for line in result.stdout.splitlines()
        if line.startswith("160000 ") and "\t" in line
    ]


def dependency_names(sections):
    """Return the dependency names a .SRCINFO declares, without constraints."""
    names = set()
    for section in sections:
        for key in ("depends", "makedepends", "checkdepends"):
            for value in section.get(key, []):
                name = VERSION_CONSTRAINT.sub("", value).strip()
                if name:
                    names.add(name)
    return names


def parse_rebuild_on(path, where):
    """Parse .rebuild-on into (sonames, packages, errors).

    `sonames` maps a soname to its provider package, `packages` is the set of
    external packages whose version drift must trigger a rebuild.
    """
    sonames = {}
    packages = {}
    errors = []
    triggers = 0
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError as exc:
        return sonames, packages, [f"{where}: cannot read: {exc}"]

    for lineno, raw in enumerate(lines, start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        triggers += 1
        fields = line.split()
        kind = fields[0]
        if kind == "soname":
            if len(fields) != 3:
                errors.append(
                    f"{where}:{lineno}: expected `<soname> <provider>` "
                    "after `soname`"
                )
                continue
            soname, provider = fields[1], fields[2]
            if not SONAME.match(soname):
                errors.append(
                    f"{where}:{lineno}: '{soname}' is not a shared library name"
                )
            if not PACKAGE_NAME.match(provider):
                errors.append(
                    f"{where}:{lineno}: '{provider}' is not a valid package name"
                )
            if soname in sonames:
                errors.append(f"{where}:{lineno}: duplicate soname trigger '{soname}'")
            sonames[soname] = provider
        elif kind == "package":
            if len(fields) != 2:
                errors.append(
                    f"{where}:{lineno}: expected `<name>` after `package`"
                )
                continue
            name = fields[1]
            if not PACKAGE_NAME.match(name):
                errors.append(f"{where}:{lineno}: '{name}' is not a valid package name")
            if name in packages:
                errors.append(f"{where}:{lineno}: duplicate package trigger '{name}'")
            packages[name] = lineno
        else:
            errors.append(
                f"{where}:{lineno}: unknown trigger '{kind}' "
                f"(expected one of: {', '.join(REBUILD_ON_KINDS)})"
            )

    if triggers == 0:
        errors.append(f"{where}: declares no triggers")
    return sonames, packages, errors


def check_rebuild_on(package_dir, sections, errors, notes):
    """Validate packages/<name>/.rebuild-on when the package has one."""
    rel = f"packages/{package_dir.name}"
    path = package_dir / ".rebuild-on"
    if not path.is_file():
        return

    where = f"{rel}/.rebuild-on"
    sonames, packages, problems = parse_rebuild_on(path, where)
    errors.extend(problems)
    if sections is None:
        return

    declared_dependencies = dependency_names(sections)
    for name in sorted(packages):
        if not PACKAGE_NAME.match(name):
            continue
        if name not in declared_dependencies:
            errors.append(
                f"{where}: `package {name}` is not one of this package's "
                "depends/makedepends/checkdepends"
            )
    if sonames:
        notes.append(f"{rel}: {len(sonames)} declared external soname(s)")


def check_package(root, package_dir, errors, notes):
    """Validate one package directory.  Returns the .SRCINFO sections, or None."""
    name = package_dir.name
    rel = f"packages/{name}"

    if not PACKAGE_NAME.match(name):
        errors.append(f"{rel}: directory name is not a valid package name")

    pkgbuild = package_dir / "PKGBUILD"
    srcinfo = package_dir / ".SRCINFO"
    if not pkgbuild.is_file():
        errors.append(f"{rel}: PKGBUILD is missing")
    if not srcinfo.is_file():
        errors.append(f"{rel}: .SRCINFO is missing")
        return None

    try:
        sections = parse_srcinfo(srcinfo)
    except OSError as exc:
        errors.append(f"{rel}: cannot read .SRCINFO: {exc}")
        return None
    if not sections:
        errors.append(f"{rel}: .SRCINFO is empty or unparseable")
        return None

    base = sections[0]
    pkgbase = (base.get("pkgbase") or [""])[0]
    if pkgbase != name:
        errors.append(f"{rel}: pkgbase is '{pkgbase}', expected '{name}'")

    names = [value for section in sections for value in section.get("pkgname", [])]
    if not names:
        errors.append(f"{rel}: .SRCINFO declares no pkgname")

    pkgver = (base.get("pkgver") or [""])[0]
    if not pkgver:
        errors.append(f"{rel}: pkgver is empty")
    elif any(character in pkgver for character in "-: \t"):
        errors.append(
            f"{rel}: pkgver '{pkgver}' contains '-', ':' or whitespace, "
            "which pacman rejects"
        )

    pkgrel = (base.get("pkgrel") or [""])[0]
    if not pkgrel:
        errors.append(f"{rel}: pkgrel is empty")
    elif not PKGREL.match(pkgrel):
        errors.append(f"{rel}: pkgrel '{pkgrel}' is not a number")

    for field in ("pkgdesc", "url"):
        if not (base.get(field) or [""])[0]:
            errors.append(f"{rel}: {field} is missing or empty")
    if not base.get("license"):
        errors.append(f"{rel}: no license declared")

    for section in sections:
        source_count = len(section.get("source", []))
        for key, values in section.items():
            if not key.endswith("sums"):
                continue
            if len(values) != source_count:
                owner = (section.get("pkgname") or section.get("pkgbase") or [name])[0]
                errors.append(
                    f"{rel}: {key} has {len(values)} entries for "
                    f"{source_count} source entries (package {owner})"
                )

    return sections


def check_update_source(root, package_dir, registry, tracked, errors, notes):
    """Enforce that the package declares exactly one update source."""
    name = package_dir.name
    rel = f"packages/{name}"
    aur_url_file = package_dir / ".aur-url"
    aur_commit_file = package_dir / ".aur-commit"
    in_registry = name in registry

    if aur_url_file.is_file() and in_registry:
        errors.append(
            f"{rel}: declares an update source twice "
            "(.aur-url and a config/package-updates.txt entry)"
        )
    if not aur_url_file.is_file() and not in_registry:
        errors.append(
            f"{rel}: no update source declared -- add .aur-url (+ .aur-commit) "
            "for an AUR package, or an entry in config/package-updates.txt"
        )

    if aur_url_file.is_file():
        urls = [
            line.strip()
            for line in aur_url_file.read_text(
                encoding="utf-8", errors="replace"
            ).splitlines()
            if line.strip()
        ]
        if len(urls) != 1:
            errors.append(f"{rel}: .aur-url must hold exactly one URL")
        else:
            url = urls[0]
            match = AUR_URL.match(url)
            if match is None:
                errors.append(
                    f"{rel}: .aur-url '{url}' is not an "
                    "https://aur.archlinux.org/<name>.git URL"
                )
            elif match.group("name") != name:
                notes.append(
                    f"{rel}: .aur-url points at AUR package "
                    f"'{match.group('name')}', not '{name}'"
                )
        commit = ""
        if aur_commit_file.is_file():
            commit = aur_commit_file.read_text(
                encoding="utf-8", errors="replace"
            ).strip()
        if not commit:
            errors.append(f"{rel}: .aur-url without .aur-commit")
        elif not GIT_COMMIT.match(commit):
            errors.append(
                f"{rel}: .aur-commit is not a 40-character git commit hash"
            )


def check_registry_entries(root, packages, registry, tracked, errors):
    """Validate that every registry entry points at something real."""
    for name, (kind, detail, lineno) in sorted(registry.items()):
        where = f"{REGISTRY_PATH}:{lineno}"
        if name not in packages:
            errors.append(f"{where}: no such package directory packages/{name}")
            continue
        if kind != "workflow":
            continue
        candidate = root / detail
        if tracked is not None:
            if detail not in tracked:
                errors.append(
                    f"{where}: {name} names workflow '{detail}', which is not "
                    "tracked by git"
                )
            continue
        if not candidate.is_file():
            errors.append(f"{where}: {name} names missing file '{detail}'")


def run(root):
    """Check the tree under root.  Returns (errors, notes, package count)."""
    errors = []
    notes = []

    packages_root = root / "packages"
    package_dirs = (
        sorted(
            (path for path in packages_root.iterdir() if path.is_dir()),
            key=lambda path: path.name,
        )
        if packages_root.is_dir()
        else []
    )
    manifests = [
        path
        for path in package_dirs
        if (path / "PKGBUILD").is_file() or (path / ".SRCINFO").is_file()
    ]
    if not manifests:
        errors.append(f"{packages_root}: no package directories containing PKGBUILD")
        return errors, notes, 0

    registry, registry_errors = load_registry(root / REGISTRY_PATH)
    errors.extend(registry_errors)
    tracked = tracked_files(root)

    for package_dir in manifests:
        sections = check_package(root, package_dir, errors, notes)
        check_update_source(root, package_dir, registry, tracked, errors, notes)
        check_rebuild_on(package_dir, sections, errors, notes)

    check_registry_entries(
        root, {path.name for path in manifests}, registry, tracked, errors
    )

    gitlinks = tracked_gitlinks(root)
    if gitlinks is None:
        notes.append("git unavailable: skipped the committed-submodule check")
    else:
        for path in gitlinks:
            errors.append(f"{path}: committed gitlink (submodule) under packages/")

    return errors, notes, len(manifests)


def main(argv=None):
    parser = argparse.ArgumentParser(
        description="Check packages/*/ manifest policy without needing makepkg."
    )
    parser.add_argument(
        "--root",
        default=None,
        help="repository root (default: the checkout that contains this script)",
    )
    args = parser.parse_args(argv)
    root = (
        Path(args.root).resolve()
        if args.root
        else Path(__file__).resolve().parents[1]
    )

    errors, notes, package_count = run(root)
    for note in notes:
        print(f"NOTE {note}")
    for error in errors:
        print(f"ERROR {error}")
    print(f"SUMMARY packages={package_count} errors={len(errors)}")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
