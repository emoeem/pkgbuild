#!/usr/bin/env python3
"""Select the package bases that a change needs to rebuild.

Thin CLI over scripts/lib/pkgbuild_lib.py, which owns the graph semantics:
provider edges (pkgname + provides), depends/makedepends/checkdepends, overlay
targeting and infrastructure paths.  The functions below are compatibility
wrappers so tests and workflows keep their existing contract.
"""

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from pkgbuild_lib import (  # noqa: E402
    PACKAGE_NAME_PATTERN,
    PackageMetadata,
    available_packages,
    changed_files,
    classify_changes,
    dumps,
    graph_consumers,
    load_packages,
    package_dirs,
    parse_srcinfo as _parse_srcinfo,
    transitive_closure,
)


def _packages(root: Path) -> dict[str, PackageMetadata]:
    return load_packages(root)


def parse_srcinfo(path: Path) -> tuple[set[str], set[str], set[str]]:
    """Return package names, provided names and dependency names from .SRCINFO."""
    metadata = _parse_srcinfo(path)
    return (
        set(metadata.packages),
        set(metadata.provides),
        set(metadata.all_dependencies()),
    )


def dependency_graph(root: Path) -> dict[str, set[str]]:
    """Map each provider package to the package bases which consume it."""
    return graph_consumers(_packages(root))


def changed_paths(root: Path, before: str, after: str) -> list[str]:
    return changed_files(root, before, after)


def affected_packages(root: Path, paths: list[str], available: set[str]) -> set[str]:
    packages = _packages(root)
    impact = classify_changes(root, paths, packages)
    if impact.infrastructure_changed:
        return set(available)
    return transitive_closure(
        impact.direct | impact.overlays, packages, graph_consumers(packages)
    )


def select(root: Path, selection: str, before: str, after: str) -> list[str]:
    available = available_packages(root)
    available_set = set(available)
    if selection in ("", "all"):
        selected = available
    elif selection == "changed":
        if not before or set(before) == {"0"}:
            # The diff is unknowable (fresh history or an all-zero
            # github.event.before): rebuild everything rather than nothing,
            # matching remove.yml's handling of the same situation.
            selected = available
        else:
            selected = sorted(
                affected_packages(root, changed_paths(root, before, after), available_set)
            )
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
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--selection", default="all")
    parser.add_argument("--before", default="")
    parser.add_argument("--after", default="HEAD")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    args = parser.parse_args()
    print(dumps(select(args.root.resolve(), args.selection, args.before, args.after)))


if __name__ == "__main__":
    main()
