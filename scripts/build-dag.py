#!/usr/bin/env python3
"""DAG scheduler and resource aware plan for a set of packages.

Turns "which packages must be rebuilt" into "what can build at the same time,
on this machine, without thrashing it":

  A ----+
        +--> C          wave 0: A, B, D
  B ----+                wave 1: C, E
  D --------> E

Packages that really depend on each other are serialised into successive waves;
everything else is free to run in parallel, bounded by measured CPU / RAM /
disk / GPU weights instead of a fixed make -j4.

Weights come from state/timing-history.jsonl when a package has been measured
and fall back to scripts/data/package-resources.yaml.
"""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from errorrules import load_yaml  # noqa: E402
from pkgbuild_lib import (  # noqa: E402
    dependency_map,
    in_repo_dependencies,
    load_packages,
    topological_order,
)

RULE = "\u2500" * 28


def load_timings(history: Path | None) -> dict[str, dict]:
    """package -> last measured record, from the JSONL history."""
    measured: dict[str, dict] = {}
    if history is None or not history.is_file():
        return measured
    for line in history.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        name = record.get("package")
        if name:
            measured[name] = record
    return measured


def load_weight_table(path: Path) -> tuple[dict[str, dict], dict[str, int]]:
    defaults = {"cpu": 2, "ram": 2, "disk": 2, "gpu": 0}
    table: dict[str, dict] = {}
    if not path.is_file():
        return table, defaults
    document = load_yaml(path.read_text(encoding="utf-8"))
    raw_defaults = document.get("defaults") or {}
    for key in defaults:
        value = raw_defaults.get(key)
        if isinstance(value, int):
            defaults[key] = value
    for name, entry in (document.get("packages") or {}).items():
        if not isinstance(entry, dict):
            continue
        table[str(name)] = {
            key: int(entry.get(key, defaults[key])) if isinstance(entry.get(key), int) else defaults[key]
            for key in defaults
        }
    return table, defaults


def weights_for(
    name: str,
    table: dict[str, dict],
    defaults: dict[str, int],
    measured: dict[str, dict],
) -> dict:
    """Prefer measured resource facts, fall back to the declared table.

    CPU time and peak memory are bucketed into the same 1..3 scale so the
    scheduler can compare a measured package against a declared one.
    """
    weight = dict(table.get(name, defaults))
    record = measured.get(name)
    source = "declared"
    if record:
        resources = record.get("resources") or {}
        cpu_seconds = float(resources.get("cpu_seconds") or 0)
        peak = float(resources.get("memory_peak_bytes") or 0)
        if cpu_seconds > 0:
            weight["cpu"] = 3 if cpu_seconds > 1800 else 2 if cpu_seconds > 300 else 1
            source = "measured"
        if peak > 0:
            weight["ram"] = 3 if peak > 8 * 1024**3 else 2 if peak > 2 * 1024**3 else 1
            source = "measured"
        weight["duration_seconds"] = float(record.get("total_seconds") or 0)
    else:
        weight["duration_seconds"] = 0.0
    weight["source"] = source
    return weight


def cycle_path(
    nodes: list[str], dependencies: dict[str, set[str]]
) -> list[str]:
    """One concrete dependency cycle among *nodes*, as [a, b, ..., a].

    The wave builder can only see "nothing is ready"; this finds *why*, so a
    broken declaration is reported as the loop it is instead of being hidden
    behind an opaque merged wave.
    """
    allowed = set(nodes)
    state: dict[str, int] = {}  # 0 = on the current path, 1 = finished
    path: list[str] = []

    def visit(node: str) -> list[str]:
        state[node] = 0
        path.append(node)
        for nxt in sorted(dependencies.get(node, set()) & allowed):
            if state.get(nxt) == 0:
                return path[path.index(nxt):] + [nxt]
            if nxt not in state:
                found = visit(nxt)
                if found:
                    return found
        path.pop()
        state[node] = 1
        return []

    for node in sorted(allowed):
        if node not in state:
            found = visit(node)
            if found:
                return found
    return []


def build_waves(
    bases: list[str], packages: dict
) -> tuple[list[list[str]], list[list[str]]]:
    """Split the selection into successive waves honouring in-repo dependencies.

    Returns the waves and the dependency cycles that had to be merged into one
    wave.  A cycle means the selection cannot be ordered: the merged wave is
    emitted so the scheduler still terminates, but the caller has to surface
    it instead of pretending the wave is a set of independent builds.
    """
    selected = set(bases)
    prerequisites = dependency_map(packages)
    dependencies: dict[str, set[str]] = {
        base: {name for name in prerequisites.get(base, set()) if name in selected}
        for base in selected
    }

    waves: list[list[str]] = []
    cycles: list[list[str]] = []
    remaining = dict(dependencies)
    while remaining:
        ready = sorted(name for name, deps in remaining.items() if not deps)
        if not ready:
            # Cycles inside the selection: emit the rest as one final wave
            # rather than looping forever, and report every cycle we can find.
            blocked = sorted(remaining)
            waves.append(blocked)
            unresolved = set(blocked)
            while unresolved:
                found = cycle_path(sorted(unresolved), dependencies)
                if not found:
                    # Only reachable through a cycle outside the leftover set.
                    break
                cycles.append(found)
                unresolved.difference_update(found[:-1])
            break
        waves.append(ready)
        for name in ready:
            del remaining[name]
        for deps in remaining.values():
            deps.difference_update(ready)
    return waves, cycles


def schedule(
    waves: list[list[str]],
    weights: dict[str, dict],
    jobs: int,
    ram_slots: int,
    gpu_slots: int,
) -> list[dict]:
    """Greedy within-wave packing under RAM and GPU limits."""
    result = []
    for index, wave in enumerate(waves):
        ordered = sorted(wave, key=lambda name: (-weights[name]["ram"], name))
        slots: list[dict] = []
        for name in ordered:
            weight = weights[name]
            placement = None
            for slot in slots:
                if len(slot["packages"]) >= jobs:
                    continue
                if slot["ram"] + weight["ram"] > ram_slots:
                    continue
                if weight["gpu"] and slot["gpu"] + weight["gpu"] > gpu_slots:
                    continue
                placement = slot
                break
            if placement is None:
                placement = {"packages": [], "ram": 0, "gpu": 0}
                slots.append(placement)
            placement["packages"].append(name)
            placement["ram"] += weight["ram"]
            placement["gpu"] += weight["gpu"]
        result.append(
            {
                "wave": index,
                "packages": wave,
                "slots": [
                    {
                        "packages": slot["packages"],
                        "ram_weight": slot["ram"],
                        "gpu_weight": slot["gpu"],
                        "estimated_seconds": round(
                            max(
                                (weights[name]["duration_seconds"] for name in slot["packages"]),
                                default=0.0,
                            ),
                            1,
                        ),
                    }
                    for slot in slots
                ],
            }
        )
    return result


def fmt(seconds: float) -> str:
    if seconds <= 0:
        return "-"
    minutes, remainder = divmod(int(seconds), 60)
    if minutes >= 60:
        hours, minutes = divmod(minutes, 60)
        return f"{hours}h{minutes:02d}m{remainder:02d}s"
    return f"{minutes}m{remainder:02d}s"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--packages", default="", help="comma separated list; defaults to every package")
    parser.add_argument("--plan", type=Path, help="build-plan.json to take the rebuild set from")
    parser.add_argument("--timing-history", type=Path, help="state/timing-history.jsonl")
    parser.add_argument("--resources", type=Path, help="scripts/data/package-resources.yaml")
    parser.add_argument("--cpus", type=int, default=0, help="available CPUs (default: os.cpu_count())")
    parser.add_argument("--memory-gb", type=int, default=0, help="available RAM in GiB")
    parser.add_argument("--gpus", type=int, default=0, help="available GPUs")
    parser.add_argument("--max-parallel-jobs", type=int, default=0, help="hard cap per slot")
    parser.add_argument("--format", choices=("text", "json"), default="text")
    parser.add_argument(
        "--prerequisites-for",
        default="",
        help="print the in-repo prerequisites of this package and exit",
    )
    args = parser.parse_args()

    root = args.root.resolve()
    packages = load_packages(root)

    if args.prerequisites_for:
        # "Which packages in this repository does this one depend on": a
        # dependency is in-repo when some package base provides that name.
        # (Asking the consumer graph instead would return every package that
        # shares a dependency such as glibc or cmake.)
        print(json.dumps(sorted(in_repo_dependencies(args.prerequisites_for, packages))))
        return

    if args.plan and args.plan.is_file():
        plan = json.loads(args.plan.read_text(encoding="utf-8"))
        selection = list(plan.get("rebuild") or [])
        make_jobs = int(plan.get("counts", {}).get("rebuild", 0))
    elif args.packages:
        selection = [item.strip() for item in args.packages.split(",") if item.strip()]
        make_jobs = len(selection)
    else:
        selection = sorted(packages)
        make_jobs = len(selection)

    unknown = sorted(set(selection) - set(packages))
    if unknown:
        raise SystemExit(f"Unknown package(s): {', '.join(unknown)}")

    table, defaults = load_weight_table(
        args.resources or root / "scripts" / "data" / "package-resources.yaml"
    )
    measured = load_timings(args.timing_history or root / "state" / "timing-history.jsonl")
    weights = {name: weights_for(name, table, defaults, measured) for name in selection}

    cpus = args.cpus or (len(selection) and __import__("os").cpu_count()) or 4
    memory_gb = args.memory_gb or 16
    gpus = args.gpus

    # Per-slot bundle: how many packages may build simultaneously, scaled down
    # when the runner is small (a 4-core box must not run three weight-3 builds).
    jobs = args.max_parallel_jobs or max(1, min(4, cpus // 4 if cpus >= 4 else 1))
    ram_slots = max(2, memory_gb // 4)
    gpu_slots = max(0, gpus)

    waves, cycles = build_waves(selection, packages)
    scheduled = schedule(waves, weights, jobs, ram_slots, gpu_slots)

    makespan = sum(
        max((slot["estimated_seconds"] for slot in wave["slots"]), default=0.0)
        for wave in scheduled
    )

    document = {
        "schema": 1,
        "counts": {
            "packages": len(selection),
            "waves": len(waves),
            "parallel_jobs_per_slot": jobs,
            "ram_slots": ram_slots,
            "gpu_slots": gpu_slots,
            "cpus": cpus,
            "memory_gb": memory_gb,
        },
        "weights": weights,
        "waves": scheduled,
        "cycles": cycles,
        "estimated_makespan_seconds": round(makespan, 1),
        "topological_order": topological_order(selection, packages),
    }

    if args.format == "json":
        print(json.dumps(document, indent=2, sort_keys=True))
        return

    if cycles:
        print("WARNING: dependency cycle(s) cannot be ordered; merged into one wave:")
        for found in cycles:
            path = " -> ".join(found)
            print(f"  {path}  ({len(found) - 1} package(s) in the loop)")
        print("Fix the .SRCINFO relations or .rebuild-on declarations above.")
        print()

    print("Build DAG")
    print(RULE)
    print()
    print(f"Packages        {len(selection)}")
    print(f"Waves           {len(waves)}")
    print(f"Slot width      {jobs} package(s), RAM budget {ram_slots}, GPU budget {gpu_slots}")
    print(f"Runner          {cpus} CPU, {memory_gb} GiB RAM, {gpus} GPU")
    print()
    for wave in scheduled:
        print(f"Wave {wave['wave']}  ({len(wave['packages'])} package(s))")
        for slot in wave["slots"]:
            names = ", ".join(
                f"{name}[cpu{weights[name]['cpu']}/ram{weights[name]['ram']}]"
                for name in slot["packages"]
            )
            estimate = fmt(slot["estimated_seconds"])
            print(f"  slot: {names}   ~{estimate}")
        print()
    if measured:
        print(f"Makespan estimate {fmt(makespan)} (from {len(measured)} measured package(s))")
    else:
        print("Makespan estimate unavailable (no timing history yet)")
    print()

    if len(waves) > 1:
        print("Serialisation required by in-repo dependencies:")
        for index, wave in enumerate(scheduled[1:], start=1):
            print(f"  wave {index}: {', '.join(wave['packages'])}")
        print()


if __name__ == "__main__":
    main()
