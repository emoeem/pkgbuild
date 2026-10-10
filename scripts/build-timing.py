#!/usr/bin/env python3
"""Build timing profiler.

Three jobs:

1. stamp    - tee a build's output while prefixing every line with a wall
              clock timestamp, so makepkg's phase banners become measurable.
2. collect  - turn the stamped log plus the orchestration phase file into one
              timings.json (download / configure / build / link / package /
              verify / smoke, plus ccache hit rate and resource usage).
3. aggregate/report/append-history - roll per-package records into the long
              term history that the planner and the DAG scheduler read.

Only measurements that are actually observable are reported: orchestration
phases come from explicit timers, makepkg phases come from its own banners.
Nothing is estimated or interpolated, so a missing phase means "not measured"
rather than "zero".
"""

from __future__ import annotations

import argparse
import json
import re
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

SCHEMA_VERSION = 1

PHASE_MARKERS: list[tuple[re.Pattern[str], str]] = [
    (re.compile(r"^==> Making package:"), "snapshot"),
    (re.compile(r"^==> Retrieving sources"), "retrieve"),
    (re.compile(r"^==> Validating source"), "validate"),
    (re.compile(r"^==> Extracting sources"), "extract"),
    (re.compile(r"^==> Starting prepare\(\)"), "prepare"),
    (re.compile(r"^==> Starting build\(\)"), "build"),
    (re.compile(r"^==> Starting check\(\)"), "check"),
    (re.compile(r"^==> Starting package"), "package"),
    (re.compile(r"^==> Tidying install"), "tidy"),
    (re.compile(r"^==> Compressing package"), "compress"),
    (re.compile(r"^==> Creating package"), "create"),
    (re.compile(r"^==> Finished making:"), "finish"),
    (re.compile(r"^==> ERROR:"), "error"),
]

#: Phases that together make up "source acquisition".
DOWNLOAD_PHASES = ("retrieve", "validate")
BUILD_PHASES = ("build", "check")

ERROR_LINE_PATTERN = re.compile(r"^==> ERROR:\s*(.*)$")
FAILED_FUNCTION_PATTERN = re.compile(r"A failure occurred in (\w+)\(\)")

CACHE_PERCENT_PATTERN = re.compile(r"\(([0-9.]+)%\)")


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def stamp(log_path: Path) -> int:
    """Tee stdin to stdout, writing timestamped copies to log_path."""
    log_path.parent.mkdir(parents=True, exist_ok=True)
    with log_path.open("w", encoding="utf-8", errors="replace") as handle:
        for line in sys.stdin:
            handle.write(f"{time.time():.6f}\t{line}")
            handle.flush()
            sys.stdout.write(line)
            sys.stdout.flush()
    return 0


def read_stamped(path: Path) -> list[tuple[float, str]]:
    lines: list[tuple[float, str]] = []
    if not path.is_file():
        return lines
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            timestamp, separator, text = raw.partition("\t")
            if not separator:
                continue
            try:
                value = float(timestamp)
            except ValueError:
                continue
            lines.append((value, text.rstrip("\n")))
    return lines


def makepkg_phases(lines: list[tuple[float, str]]) -> tuple[dict[str, float], str, str]:
    """Durations between consecutive makepkg phase banners."""
    boundaries: list[tuple[float, str]] = []
    error_message = ""
    failed_function = ""
    for timestamp, text in lines:
        for pattern, phase in PHASE_MARKERS:
            if pattern.search(text):
                # Only the first occurrence of a banner starts a phase; split
                # packages repeat "Creating package" and those repeats are
                # folded back into the create phase below.
                boundaries.append((timestamp, phase))
                break
        if not error_message:
            match = ERROR_LINE_PATTERN.search(text)
            if match:
                error_message = match.group(1).strip()
        if not failed_function:
            match = FAILED_FUNCTION_PATTERN.search(text)
            if match:
                failed_function = match.group(1)
    phases: dict[str, float] = {}
    for index in range(len(boundaries) - 1):
        phase = boundaries[index][1]
        duration = boundaries[index + 1][0] - boundaries[index][0]
        if duration < 0:
            continue
        phases[phase] = round(phases.get(phase, 0.0) + duration, 3)
    if len(boundaries) >= 2 and boundaries[-1][1] not in ("finish", "error"):
        # The build stopped mid-phase (crash or kill): record what we saw.
        phases.setdefault("unfinished", 0.0)
    status = "failed" if error_message else "success"
    return phases, status, (failed_function or error_message)


def parse_ccache(stats_path: Path) -> dict[str, float | int | None]:
    """Parse ccache -s output from either the 3.x or the 4.x layout."""
    result: dict[str, float | int | None] = {
        "hits": None,
        "misses": None,
        "calls": None,
        "hit_rate": None,
    }
    if not stats_path.is_file():
        return result
    text = stats_path.read_text(encoding="utf-8", errors="replace")
    for line in text.splitlines():
        stripped = line.strip()
        lowered = stripped.lower()
        numbers = [int(token.replace(",", "")) for token in re.findall(r"\d[\d,]*", stripped)]
        if lowered.startswith("cache hit") and result["hits"] is None and numbers:
            result["hits"] = numbers[-1]
        elif lowered.startswith("hits:") and numbers:
            result["hits"] = numbers[0]
        elif lowered.startswith("cache miss") and result["misses"] is None and numbers:
            result["misses"] = numbers[-1]
        elif lowered.startswith("misses:") and numbers:
            result["misses"] = numbers[0]
        elif "cacheable calls" in lowered and numbers:
            result["calls"] = numbers[0]
    hits, misses = result["hits"], result["misses"]
    if isinstance(hits, int) and isinstance(misses, int) and hits + misses > 0:
        result["hit_rate"] = round(hits / (hits + misses), 4)
    return result


def read_phases(path: Path) -> dict[str, float]:
    """Read the JSONL phase file written by scripts/lib/timing.sh."""
    phases: dict[str, float] = {}
    if not path.is_file():
        return phases
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        line = line.strip()
        if not line:
            continue
        try:
            record = json.loads(line)
        except json.JSONDecodeError:
            continue
        phase = record.get("phase")
        seconds = record.get("seconds")
        if phase and isinstance(seconds, (int, float)):
            phases[phase] = round(phases.get(phase, 0.0) + float(seconds), 3)
    return phases


def read_resources(path: Path) -> dict[str, float]:
    resources: dict[str, float] = {}
    if not path.is_file():
        return resources
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        key, separator, value = line.partition("=")
        if not separator:
            continue
        try:
            resources[key.strip()] = float(value.strip())
        except ValueError:
            continue
    return resources


def collect(args: argparse.Namespace) -> int:
    log_lines = read_stamped(args.log)
    makepkg, log_status, failure = makepkg_phases(log_lines)
    orchestration = read_phases(args.phases) if args.phases else {}

    phases = dict(makepkg)
    for name, seconds in orchestration.items():
        phases[name] = round(phases.get(name, 0.0) + seconds, 3)

    download = sum(phases.get(name, 0.0) for name in DOWNLOAD_PHASES)
    compile_seconds = sum(phases.get(name, 0.0) for name in BUILD_PHASES)

    status = args.status or log_status
    record = {
        "schema": SCHEMA_VERSION,
        "package": args.package,
        "pkgver": args.pkgver,
        "status": status,
        "generated_at": utc_now(),
        "total_seconds": round(orchestration.get("total", 0.0), 3),
        "phases": phases,
        "summary": {
            "download_seconds": round(download, 3),
            "compile_seconds": round(compile_seconds, 3),
            "package_seconds": round(phases.get("package", 0.0), 3),
            "dependency_seconds": round(phases.get("dependencies", 0.0), 3),
            "verify_seconds": round(phases.get("verify", 0.0), 3),
            "smoke_seconds": round(phases.get("smoke", 0.0), 3),
        },
        "cache": parse_ccache(args.ccache) if args.ccache else {},
        "resources": read_resources(args.resources) if args.resources else {},
        "failure": failure,
        "log": args.log.name if args.log else "",
    }
    output = json.dumps(record, indent=2) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(output, encoding="utf-8")
    sys.stdout.write(output)
    return 0


def load_records(directory: Path) -> list[dict]:
    records = []
    for path in sorted(directory.rglob("timings.json")):
        try:
            records.append(json.loads(path.read_text(encoding="utf-8")))
        except (json.JSONDecodeError, OSError):
            continue
    return records


def aggregate(args: argparse.Namespace) -> int:
    records = load_records(args.dir)
    totals = [float(record.get("total_seconds", 0) or 0) for record in records]
    failures = [record for record in records if record.get("status") != "success"]
    hits = sum(int(record.get("cache", {}).get("hits") or 0) for record in records)
    misses = sum(int(record.get("cache", {}).get("misses") or 0) for record in records)
    grouped: dict[str, dict] = {}
    for record in records:
        name = record.get("package", "unknown")
        entry = grouped.setdefault(name, {"package": name, "runs": 0, "total": 0.0})
        entry["runs"] += 1
        entry["total"] += float(record.get("total_seconds", 0) or 0)
        entry["last_status"] = record.get("status")
        entry["pkgver"] = record.get("pkgver") or entry.get("pkgver", "")
    packages = sorted(
        (
            {
                "package": name,
                "runs": entry["runs"],
                "total_seconds": round(entry["total"] / max(entry["runs"], 1), 3),
                "last_status": entry.get("last_status", ""),
                "pkgver": entry.get("pkgver", ""),
            }
            for name, entry in grouped.items()
        ),
        key=lambda item: item["total_seconds"],
        reverse=True,
    )
    summary = {
        "schema": SCHEMA_VERSION,
        "generated_at": utc_now(),
        "packages": packages,
        "totals": {
            "packages": len(records),
            "unique_packages": len(packages),
            "seconds": round(sum(totals), 3),
            "failures": len(failures),
            "cache_hits": hits,
            "cache_misses": misses,
            "cache_hit_rate": round(hits / (hits + misses), 4) if hits + misses else None,
        },
    }
    output = json.dumps(summary, indent=2) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(output, encoding="utf-8")
    print(output, end="")
    return 0


def fmt(seconds: float) -> str:
    if seconds <= 0:
        return "-"
    minutes, remainder = divmod(int(seconds), 60)
    if minutes >= 60:
        hours, minutes = divmod(minutes, 60)
        return f"{hours}h{minutes:02d}m{remainder:02d}s"
    return f"{minutes}m{remainder:02d}s"


def report(args: argparse.Namespace) -> int:
    if not args.db.is_file():
        print("no timing history yet", file=sys.stderr)
        return 0
    data = json.loads(args.db.read_text(encoding="utf-8"))
    totals = data.get("totals", {})
    print("Build Timing")
    print("\u2500" * 28)
    print()
    print(f"Runs recorded   {totals.get('packages', 0)}")
    print(f"Total time      {fmt(float(totals.get('seconds', 0)))}")
    rate = totals.get("cache_hit_rate")
    print(f"ccache hit rate {'n/a' if rate is None else f'{rate * 100:.1f}%'}")
    print(f"Failures        {totals.get('failures', 0)}")
    print()
    print(f"{'package':<38}{'last':>10}{'runs':>6}  status")
    for entry in data.get("packages", [])[: args.top]:
        print(
            f"{entry['package']:<38}{fmt(float(entry['total_seconds'])):>10}"
            f"{entry['runs']:>6}  {entry.get('last_status', '')}"
        )
    print()
    return 0


def append_history(args: argparse.Namespace) -> int:
    records = load_records(args.dir)
    if not records:
        print("no timing records to append", file=sys.stderr)
        return 0
    args.history.parent.mkdir(parents=True, exist_ok=True)
    with args.history.open("a", encoding="utf-8") as handle:
        for record in sorted(records, key=lambda item: item.get("package", "")):
            entry = {
                "package": record.get("package"),
                "pkgver": record.get("pkgver"),
                "status": record.get("status"),
                "total_seconds": record.get("total_seconds"),
                "phases": record.get("phases", {}),
                "cache": record.get("cache", {}),
                "resources": record.get("resources", {}),
                "generated_at": record.get("generated_at"),
            }
            handle.write(json.dumps(entry, separators=(",", ":"), sort_keys=True) + "\n")
    print(f"appended {len(records)} timing record(s) to {args.history}")
    return 0


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    subparsers = parser.add_subparsers(dest="command", required=True)

    stamp_parser = subparsers.add_parser("stamp", help="timestamp a stream into --log")
    stamp_parser.add_argument("--log", type=Path, required=True)
    stamp_parser.set_defaults(func=lambda args: stamp(args.log))

    collect_parser = subparsers.add_parser("collect", help="build one timings.json")
    collect_parser.add_argument("--package", required=True)
    collect_parser.add_argument("--pkgver", default="")
    collect_parser.add_argument("--log", type=Path)
    collect_parser.add_argument("--phases", type=Path)
    collect_parser.add_argument("--ccache", type=Path)
    collect_parser.add_argument("--resources", type=Path)
    collect_parser.add_argument("--status", default="")
    collect_parser.add_argument("--out", type=Path)
    collect_parser.set_defaults(func=collect)

    aggregate_parser = subparsers.add_parser("aggregate", help="merge a directory of timings.json")
    aggregate_parser.add_argument("--dir", type=Path, required=True)
    aggregate_parser.add_argument("--out", type=Path)
    aggregate_parser.set_defaults(func=aggregate)

    report_parser = subparsers.add_parser("report", help="human readable timing summary")
    report_parser.add_argument("--db", type=Path, required=True)
    report_parser.add_argument("--top", type=int, default=10)
    report_parser.set_defaults(func=report)

    history_parser = subparsers.add_parser("append-history", help="append records to the history JSONL")
    history_parser.add_argument("--dir", type=Path, required=True)
    history_parser.add_argument("--history", type=Path, required=True)
    history_parser.set_defaults(func=append_history)

    args = parser.parse_args()
    raise SystemExit(args.func(args))


if __name__ == "__main__":
    main()
