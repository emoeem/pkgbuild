#!/usr/bin/env python3

import argparse
import json
import re
import subprocess
from pathlib import Path


PACKAGE_NAME_PATTERN = re.compile(r"^[A-Za-z0-9@._+-]+$")
DEPENDENCY_OPERATOR_PATTERN = re.compile(r"^([^<>=]+)(?:[<>=].*)?$")


def package_dirs(root: Path) -> list[Path]:
    return sorted(
        path.parent
        for path in (root / "packages").glob("*/PKGBUILD")
        if path.is_file() and PACKAGE_NAME_PATTERN.fullmatch(path.parent.name)
    )


def parse_srcinfo(path: Path) -> tuple[set[str], set[str], set[str]]:
    """Return package names, provided names and dependency names from .SRCINFO."""
    packages: set[str] = set()
    provides: set[str] = set()
    depends: set[str] = set()
    current_pkg = False
    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("pkgname = "):
            packages.add(line.removeprefix("pkgname = "))
            current_pkg = True
        elif current_pkg and line.startswith("\tprovides = "):
            provides.add(line.removeprefix("\tprovides = "))
        elif current_pkg and line.startswith("\tdepends = "):
            depends.add(line.removeprefix("\tdepends = "))
    return packages, provides, depends


def dependency_name(dependency: str) -> str:
    match = DEPENDENCY_OPERATOR_PATTERN.match(dependency)
    return match.group(1) if match else dependency


def dependency_graph(root: Path) -> dict[str, set[str]]:
    """Map each provider package to package bases which consume it.

    A dependency may be satisfied by a package's own pkgname or any provides
    entry. This covers virtual packages and soname provides without needing
    to evaluate pacman's full dependency solver.
    """
    provider_to_consumers: dict[str, set[str]] = {}
    metadata: list[tuple[str, set[str], set[str]]] = []
    for directory in package_dirs(root):
        srcinfo = directory / ".SRCINFO"
        if not srcinfo.is_file():
            continue
        names, provides, depends = parse_srcinfo(srcinfo)
        if not names:
            names = {directory.name}
        metadata.append((directory.name, names | provides, depends))

    for package_base, provided_names, depends in metadata:
        for provided in provided_names:
            provider_to_consumers.setdefault(provided, set())
        for dependency in depends:
            name = dependency_name(dependency)
            for provided in provided_names:
                provider_to_consumers.setdefault(provided, set())
            provider_to_consumers.setdefault(name, set()).add(package_base)
    return provider_to_consumers


def available_packages(root: Path) -> list[str]:
    return [path.name for path in package_dirs(root)]


def changed_paths(root: Path, before: str, after: str) -> list[str]:
    if not before or set(before) == {"0"}:
        return ["scripts/"]
    result = subprocess.run(
        ["git", "diff", "--name-only", before, after],
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def affected_packages(root: Path, paths: list[str], available: set[str]) -> set[str]:
    selected: set[str] = set()
    infrastructure = False
    for path in paths:
        parts = path.split("/")
        if path.startswith("config/") or path == "scripts/build-in-arch.sh":
            infrastructure = True
        if path.startswith("scripts/setup-build-repositories.sh"):
            infrastructure = True
        if len(parts) >= 3 and parts[0] == "packages" and parts[1] in available:
            selected.add(parts[1])
        if len(parts) == 3 and parts[0:2] == ["scripts", "overlays"]:
            overlay_package = parts[2].removesuffix(".sh")
            if overlay_package in available:
                selected.add(overlay_package)
    if infrastructure:
        return set(available)

    graph = dependency_graph(root)
    changed = True
    while changed:
        changed = False
        for provider in list(selected):
            for consumer in graph.get(provider, set()):
                if consumer in available and consumer not in selected:
                    selected.add(consumer)
                    changed = True
            directory = root / "packages" / provider
            srcinfo = directory / ".SRCINFO"
            if srcinfo.is_file():
                names, provides, _ = parse_srcinfo(srcinfo)
                for provided in names | provides:
                    for consumer in graph.get(provided, set()):
                        if consumer in available and consumer not in selected:
                            selected.add(consumer)
                            changed = True
    return selected


def select(root: Path, selection: str, before: str, after: str) -> list[str]:
    available = available_packages(root)
    available_set = set(available)
    if selection in ("", "all"):
        selected = available
    elif selection == "changed":
        selected = sorted(affected_packages(root, changed_paths(root, before, after), available_set))
    else:
        selected = sorted({item.strip() for item in selection.split(",") if item.strip()})

    unknown = sorted(set(selected) - available_set)
    if unknown:
        raise SystemExit(f"Unknown package(s): {', '.join(unknown)}")
    invalid = sorted(item for item in selected if not PACKAGE_NAME_PATTERN.fullmatch(item))
    if invalid:
        raise SystemExit(f"Invalid package name(s): {', '.join(invalid)}")
    return selected


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--selection", default="all")
    parser.add_argument("--before", default="")
    parser.add_argument("--after", default="HEAD")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    print(json.dumps(select(args.root.resolve(), args.selection, args.before, args.after), separators=(",", ":")))


if __name__ == "__main__":
    main()
