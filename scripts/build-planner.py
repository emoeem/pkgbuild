#!/usr/bin/env python3
"""Build Plan generator: turn a Git change into an explicit rebuild decision.

Inputs
------
* the Git diff (files changed between --before and --after),
* package metadata (packages/*/.SRCINFO),
* the provider -> consumer dependency graph,
* overlay changes (scripts/overlays/<package>.sh),
* optional repository state (the published ABI manifest),
* optional timing history (to estimate the cost of the plan).

Outputs
-------
* a machine readable plan (JSON) with changed / affected / rebuild / skipped
  and a per-package reason,
* a human readable plan (the default stdout format),
* optionally plan.json + plan.txt + GitHub Actions outputs written to --out.

The plan is the single place that decides "what will CI build and why", so the
log of a run can always answer "why was package X rebuilt / skipped".
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from pkgbuild_lib import (  # noqa: E402
    PACKAGE_NAME_PATTERN,
    ChangeImpact,
    PackageMetadata,
    changed_files,
    classify_changes,
    dumps,
    graph_consumers,
    load_packages,
    topological_order,
)
SCHEMA_VERSION = 1
RULE = "\u2500" * 28


def _utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def propagate(
    packages: dict[str, PackageMetadata], direct: set[str]
) -> tuple[set[str], dict[str, list[str]]]:
    """Broadest first: return every affected base plus the edge that caused it."""
    graph = graph_consumers(packages)
    reasons: dict[str, list[str]] = {name: [] for name in direct}
    seen = set(direct)
    frontier = set(direct)
    while frontier:
        nxt: set[str] = set()
        for base in sorted(frontier):
            metadata = packages.get(base)
            names = {base}
            if metadata is not None:
                names |= set(metadata.providers)
            for name in sorted(names):
                for consumer in sorted(graph.get(name, ())):
                    if consumer not in packages or consumer in seen:
                        continue
                    seen.add(consumer)
                    nxt.add(consumer)
                    reasons.setdefault(consumer, []).append(
                        f"dependency: {name} (provided by {base})"
                    )
        frontier = nxt
    return seen, reasons


def parse_manifest(path: Path) -> dict[str, str]:
    """Read a published ABI manifest: pkg<TAB>version<TAB>needed... -> version."""
    versions: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        if not line or line.startswith("#"):
            continue
        parts = line.split("\t")
        if len(parts) < 2:
            continue
        versions[parts[0]] = parts[1]
    return versions


def normalize_version(version: str) -> str:
    """Drop a leading epoch so 1:4.7.0-1 and 4.7.0-1 compare equal."""
    if ":" in version:
        return version.split(":", 1)[1]
    return version


def repository_drift(
    packages: dict[str, PackageMetadata], manifest: dict[str, str]
) -> dict[str, list[str]]:
    """Published version vs source version, per pkgname and package base."""
    reasons: dict[str, list[str]] = {}
    for base, metadata in packages.items():
        published = set()
        for name in metadata.packages or (base,):
            if name in manifest:
                published.add(normalize_version(manifest[name]))
        if not published:
            continue
        source = normalize_version(metadata.version)
        if source and source not in published:
            reasons.setdefault(base, []).append(
                "repository: published "
                + ", ".join(sorted(published))
                + f" != source {source or 'unknown'}"
            )
    return reasons


def load_timing_db(path: Path | None) -> dict[str, float]:
    if path is None:
        return {}
    if not path.is_file():
        return {}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return {}
    durations: dict[str, float] = {}
    for entry in data.get("packages", []):
        name = entry.get("package")
        if name:
            durations[name] = float(entry.get("total_seconds", 0) or 0)
    return durations


def build_plan(
    root: Path,
    selection: str,
    before: str,
    after: str,
    manifest_path: Path | None = None,
    timing_db: Path | None = None,
    builder_generation: str = "",
) -> dict:
    packages = load_packages(root)
    available = sorted(packages)
    available_set = set(available)

    # An empty impact until the diff is known; replaced below for "changed".
    impact = ChangeImpact()
    direct: set[str] = set()
    overlay: set[str] = set()
    reasons: dict[str, list[str]] = {}
    diff_lines: list[str] = []

    if selection in ("", "all"):
        direct = set(available)
        for base in available:
            reasons.setdefault(base, []).append("selection: full rebuild requested")
    elif selection == "changed":
        if not before or set(before) == {"0"}:
            direct = set(available)
            for base in available:
                reasons.setdefault(base, []).append(
                    "selection: unknowable diff (all-zero before-SHA) -> full rebuild"
                )
        else:
            diff_lines = changed_files(root, before, after)
            impact = classify_changes(root, diff_lines, packages)
            overlay = set(impact.overlays)
            # An overlay change is a direct trigger for its package, exactly
            # like editing the PKGBUILD itself; the overlay set is kept
            # separately so the plan can say which kind of change it was.
            direct = set(impact.direct) | overlay
            for base, why in impact.reasons.items():
                reasons.setdefault(base, []).extend(why)
    else:
        requested = sorted({item.strip() for item in selection.split(",") if item.strip()})
        unknown = sorted(set(requested) - available_set)
        if unknown:
            raise SystemExit(f"Unknown package(s): {', '.join(unknown)}")
        invalid = sorted(item for item in requested if not PACKAGE_NAME_PATTERN.fullmatch(item))
        if invalid:
            raise SystemExit(f"Invalid package name(s): {', '.join(invalid)}")
        direct = set(requested)
        for base in requested:
            reasons.setdefault(base, []).append("selection: explicitly requested")

    if impact.infrastructure_changed:
        direct |= available_set
        for base in available:
            reasons.setdefault(base, []).append(
                "infrastructure: " + ", ".join(sorted(impact.infrastructure)[:3])
            )

    affected, dependency_reasons = propagate(packages, direct)
    for base, why in dependency_reasons.items():
        reasons.setdefault(base, []).extend(why)

    drift_reasons: dict[str, list[str]] = {}
    if manifest_path is not None and manifest_path.is_file():
        drift_reasons = repository_drift(packages, parse_manifest(manifest_path))
        affected |= set(drift_reasons)
        for base, why in drift_reasons.items():
            reasons.setdefault(base, []).extend(why)

    rebuild = sorted(affected, key=lambda name: (available.index(name), name))
    order = topological_order(rebuild, packages)
    skipped = sorted(available_set - affected)

    durations = load_timing_db(timing_db)
    estimates = {name: durations.get(name, 0.0) for name in rebuild}

    plan = {
        "schema": SCHEMA_VERSION,
        "generated_at": _utc_now(),
        "selection": selection or "all",
        "before": before,
        "after": after,
        "builder_generation": builder_generation,
        "infrastructure": {
            "changed": impact.infrastructure_changed,
            "paths": sorted(impact.infrastructure),
        },
        "direct": sorted(direct),
        "changed": sorted(direct),
        "overlay": sorted(overlay),
        "affected": sorted(affected - direct),
        "rebuild": rebuild,
        "build_order": order,
        "skipped": skipped,
        "reason": {name: reasons.get(name, []) for name in rebuild},
        "repository": {
            "manifest_checked": bool(manifest_path and manifest_path.is_file()),
            "drift": sorted(drift_reasons),
        },
        "counts": {
            "available": len(available),
            "direct": len(direct),
            "affected": len(affected - direct),
            "rebuild": len(rebuild),
            "skipped": len(skipped),
            "diff_files": len(diff_lines),
        },
        "estimated": {
            "seconds": round(sum(estimates.values()), 1),
            "per_package": {name: round(value, 1) for name, value in estimates.items()},
            "source": "timing-history" if durations else "none",
        },
    }
    return plan


def _fmt_seconds(seconds: float) -> str:
    if seconds <= 0:
        return "-"
    minutes, remainder = divmod(int(seconds), 60)
    if minutes >= 60:
        hours, minutes = divmod(minutes, 60)
        return f"{hours}h{minutes:02d}m{remainder:02d}s"
    return f"{minutes}m{remainder:02d}s"


def _column(plan: dict) -> int:
    names = list(plan["changed"]) + list(plan["affected"])
    width = max((len(name) for name in names), default=0)
    return min(max(width + 3, 24), 40)


def render_text(plan: dict) -> str:
    counts = plan["counts"]
    width = _column(plan)
    lines: list[str] = []
    lines.append("Build Plan")
    lines.append(RULE)
    lines.append("")
    scope = plan["selection"]
    if plan["before"]:
        scope += f" ({plan['before'][:8]}..{(plan['after'] or 'HEAD')[:8]})"
    lines.append(f"Selection      {scope}")
    if plan["before"]:
        lines.append(f"Changed files  {counts['diff_files']}")
    if plan["builder_generation"]:
        lines.append(f"Builder        {plan['builder_generation']}")
    lines.append("")

    lines.append("Direct changes")
    if plan["changed"]:
        for name in plan["changed"]:
            why = plan["reason"].get(name, [""])[0] if plan["reason"].get(name) else ""
            lines.append(f"  {name:<{width}}{why}")
    else:
        lines.append("  none")

    lines.append("")
    lines.append("Overlay changes")
    lines.append("  " + (", ".join(plan["overlay"]) if plan["overlay"] else "none"))

    lines.append("")
    lines.append("Dependency impact")
    if plan["affected"]:
        for name in plan["affected"]:
            why = plan["reason"].get(name, [""])[0] if plan["reason"].get(name) else ""
            lines.append(f"  {name:<{width}}{why}")
    else:
        lines.append("  none")

    if plan["repository"]["drift"]:
        lines.append("")
        lines.append("Repository drift")
        for name in plan["repository"]["drift"]:
            lines.append(f"  {name}")

    lines.append("")
    lines.append("Infrastructure impact")
    lines.append(
        "  " + (", ".join(plan["infrastructure"]["paths"]) if plan["infrastructure"]["changed"] else "none")
    )

    lines.append("")
    lines.append("Skipped packages")
    lines.append(f"  {counts['skipped']}")
    if plan["skipped"]:
        shown = ", ".join(plan["skipped"][:6])
        if len(plan["skipped"]) > 6:
            shown += f", ... (+{len(plan['skipped']) - 6})"
        lines.append(f"  {shown}")

    lines.append("")
    lines.append("Total")
    lines.append(f"  {counts['rebuild']} / {counts['available']}")
    if plan["estimated"]["source"] == "timing-history":
        lines.append(f"  estimated {_fmt_seconds(plan['estimated']['seconds'])}")
    lines.append("")
    return "\n".join(lines)


def write_outputs(plan: dict, out_dir: Path, github_output: Path | None) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    (out_dir / "plan.json").write_text(json.dumps(plan, indent=2) + "\n", encoding="utf-8")
    (out_dir / "plan.txt").write_text(render_text(plan) + "\n", encoding="utf-8")
    if github_output is not None:
        with github_output.open("a", encoding="utf-8") as handle:
            handle.write(f"packages={dumps(plan['rebuild'])}\n")
            handle.write(f"rebuild={dumps(plan['rebuild'])}\n")
            handle.write(f"skipped={dumps(plan['skipped'])}\n")
            handle.write(f"reason={dumps(plan['reason'])}\n")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--selection", default="all", help="changed | all | comma separated package names")
    parser.add_argument("--before", default="")
    parser.add_argument("--after", default="HEAD")
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--format", choices=("text", "json", "both"), default="text")
    parser.add_argument("--out", type=Path, help="directory receiving plan.json / plan.txt")
    parser.add_argument("--github-output", type=Path, help="file to append GH Actions outputs to")
    parser.add_argument("--repository-manifest", type=Path, help="published *-abi-manifest.txt")
    parser.add_argument("--timing-db", type=Path, help="aggregated timing history JSON")
    parser.add_argument("--builder-generation", default="")
    args = parser.parse_args()

    plan = build_plan(
        args.root.resolve(),
        args.selection,
        args.before,
        args.after,
        manifest_path=args.repository_manifest,
        timing_db=args.timing_db,
        builder_generation=args.builder_generation,
    )

    if args.out is not None:
        write_outputs(plan, args.out, args.github_output)
    elif args.github_output is not None:
        write_outputs(plan, Path("."), args.github_output)

    if args.format == "json":
        print(json.dumps(plan, indent=2))
    else:
        print(render_text(plan))
        if args.format == "both":
            print(json.dumps(plan, indent=2))


if __name__ == "__main__":
    main()
