#!/usr/bin/env python3
"""Resolve a tracked/upstream name to exactly one update route."""
from __future__ import annotations

import argparse
import tomllib
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument("--package", required=True)
    args = parser.parse_args()

    package = args.package
    package_dir = args.root / "packages" / package
    if package_dir.is_dir():
        if (package_dir / ".aur-url").is_file():
            print("aur\t" + package)
            return 0
        registry = args.root / "config" / "package-updates.txt"
        if registry.is_file():
            for raw in registry.read_text(encoding="utf-8").splitlines():
                line = raw.strip()
                if not line or line.startswith("#"):
                    continue
                parts = line.split(None, 2)
                if len(parts) >= 2 and parts[0] == package:
                    print(f"{parts[1]}\t{parts[2] if len(parts) == 3 else ''}")
                    return 0
        print("unknown\t")
        return 3

    for nv_path in sorted((args.root / "packages").glob("*/.nvchecker.toml")):
        data = tomllib.loads(nv_path.read_text(encoding="utf-8"))
        if package not in data:
            continue
        owner = nv_path.parent.name
        print("vendored\t" + owner)
        return 0

    print("unknown\t")
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
