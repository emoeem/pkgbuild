#!/usr/bin/env python3

import argparse
import json
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
PACKAGES_DIR = ROOT / "packages"
INFRASTRUCTURE_PREFIXES = (
    ".github/workflows/build.yml",
    "config/",
    "scripts/",
)


def available_packages() -> list[str]:
    return sorted(
        path.parent.name
        for path in PACKAGES_DIR.glob("*/PKGBUILD")
        if path.is_file()
    )


def changed_paths(before: str, after: str) -> list[str]:
    if not before or set(before) == {"0"}:
        return ["scripts/"]

    result = subprocess.run(
        ["git", "diff", "--name-only", before, after],
        cwd=ROOT,
        check=True,
        capture_output=True,
        text=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def select(selection: str, before: str, after: str) -> list[str]:
    available = available_packages()
    available_set = set(available)

    if selection in ("", "all"):
        selected = available
    elif selection == "changed":
        paths = changed_paths(before, after)
        if any(path.startswith(INFRASTRUCTURE_PREFIXES) for path in paths):
            selected = available
        else:
            selected = sorted(
                {
                    parts[1]
                    for path in paths
                    if (parts := path.split("/"))
                    and len(parts) >= 3
                    and parts[0] == "packages"
                }
            )
    else:
        selected = sorted(
            {item.strip() for item in selection.split(",") if item.strip()}
        )

    unknown = sorted(set(selected) - available_set)
    if unknown:
        raise SystemExit(f"Unknown package(s): {', '.join(unknown)}")

    return selected


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--selection", default="all")
    parser.add_argument("--before", default="")
    parser.add_argument("--after", default="HEAD")
    args = parser.parse_args()

    print(
        json.dumps(
            select(args.selection, args.before, args.after),
            ensure_ascii=True,
            separators=(",", ":"),
        )
    )


if __name__ == "__main__":
    main()
