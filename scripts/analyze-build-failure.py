#!/usr/bin/env python3
"""Build failure analyzer.

Reads a build log (optionally timestamped by build-timing.py) plus whatever
context the caller has, and emits a structured failure record:

    Failure
    --------------------
    Package: ffmpeg-full
    Stage:   link
    Category: SONAMEError
    Root cause: missing shared object liboapv.so.2
    Provider: openapv
    ABI mismatch: YES
    Dependents: mpv
    Recommended action: rebuild ffmpeg-full
    Auto-fix: level3 (requires rebuild + validation)
    Confidence: high

The classification comes from scripts/data/build-errors/*.yaml, so a new kind
of failure can be taught once instead of being re-diagnosed by reading a
multi-thousand-line log every time.

It also assembles the artifacts/build-report/ bundle that every failed build
uploads.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))

from errorrules import Rule, load_rule_files  # noqa: E402
from pkgbuild_lib import (  # noqa: E402
    dependency_name,
    graph_consumers,
    load_packages,
)

TIMESTAMP_PREFIX = re.compile(r"^[0-9]+[.][0-9]+\t")
FAILED_FUNCTION = re.compile(r"A failure occurred in ([a-zA-Z0-9_]+)[(][)]")
MAKEPKG_BANNER = re.compile(r"^==> (?:Starting|ERROR|Making package)")
STAGE_BANNERS = (
    ("==> Starting prepare()", "prepare"),
    ("==> Starting build()", "compile"),
    ("==> Starting check()", "check"),
    ("==> Starting package", "package"),
    ("==> Tidying install", "package"),
)
SONAME_PATTERN = re.compile(r"lib[A-Za-z0-9+._-]*[.]so(?:[.][0-9]+)*")
MAX_LOG_BYTES = 4 * 1024 * 1024


def utc_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_log(path: Path) -> list[str]:
    if not path.is_file():
        return []
    lines: list[str] = []
    with path.open("r", encoding="utf-8", errors="replace") as handle:
        for raw in handle:
            lines.append(TIMESTAMP_PREFIX.sub("", raw.rstrip("\n")))
    return lines


def collect_missing_libraries(lines: list[str]) -> list[str]:
    """Shared objects an ELF object needs but the system cannot find."""
    missing = set()
    for line in lines:
        if "not found" not in line and "cannot open shared object" not in line:
            continue
        match = SONAME_PATTERN.search(line)
        if match:
            missing.add(match.group(0))
    return sorted(missing)


def detect_stage(lines: list[str]) -> str:
    stage = "unknown"
    for line in lines:
        for banner, name in STAGE_BANNERS:
            if line.startswith(banner):
                stage = name
    return stage


def classify(
    lines: list[str], rules: list[Rule], hinted_stage: str, missing_libraries: list[str]
) -> list[dict]:
    """Return every matching rule with its evidence, best candidate first.

    Ranking is deliberately biased towards the rule that can actually act: a
    vanished SONAME also produces a downstream "cannot find -l" linker error,
    and reporting the consequence instead of the cause is what makes a SONAME
    drift look like a generic link failure. A rule that asks for provider
    inspection / a dependent rebuild therefore outranks a pure symptom rule
    when shared objects are missing.
    """
    findings = []
    for rule in rules:
        evidence = []
        for line in lines:
            if rule.match(line):
                evidence.append(line.strip()[:400])
                if len(evidence) >= 5:
                    break
        if not evidence:
            continue
        score = float(rule.score)
        if rule.stage == hinted_stage:
            score += 1
        if missing_libraries and (
            rule.action.get("trigger_rebuild") or rule.action.get("inspect_provider")
        ):
            score += 2
        if len(missing_libraries) > 1:
            score += min(len(missing_libraries), 3) * 0.1
        findings.append({"rule": rule, "evidence": evidence, "score": score})
    findings.sort(key=lambda item: (-item["score"], item["rule"].id))
    return findings


def extract_fields(rule: Rule, lines: list[str]) -> dict[str, str]:
    fields: dict[str, str] = {}
    for key, pattern in rule.extract.items():
        for line in lines:
            match = pattern.search(line)
            if match and match.groups():
                value = match.group(1).strip()
                if key == "soname":
                    # Keep only the soname itself; the sample often continues
                    # with ": cannot open shared object file".
                    soname = SONAME_PATTERN.search(value)
                    if soname:
                        value = soname.group(0)
                if value:
                    fields[key] = value
                    break
    return fields


def resolve_providers(
    soname: str,
    root: Path,
    packages: dict,
    repository_dir: Path | None,
    external_file: Path | None,
) -> list[str]:
    """Who can supply *soname*? Package bases, or "external"."""
    providers: set[str] = set()
    normalized = None
    match = re.fullmatch(r"(.*[.]so)[=]([0-9][0-9.]*)(-[0-9]+)?", soname)
    if match:
        normalized = f"{match.group(1)}.{match.group(2)}"

    for base, metadata in packages.items():
        for provided in metadata.provides:
            candidate = provided
            match = re.fullmatch(r"(.*[.]so)[=]([0-9][0-9.]*)(-[0-9]+)?", provided)
            if match:
                candidate = f"{match.group(1)}.{match.group(2)}"
            if candidate == soname or (normalized and candidate == normalized):
                providers.add(base)

    if repository_dir and repository_dir.is_dir():
        for package_file in sorted(repository_dir.glob("*.pkg.tar.zst")):
            try:
                listing = subprocess.run(
                    ["bsdtar", "-tf", str(package_file)],
                    capture_output=True,
                    text=True,
                    timeout=120,
                ).stdout
            except (OSError, subprocess.TimeoutExpired):
                continue
            if soname not in {name.rsplit("/", 1)[-1] for name in listing.splitlines()}:
                continue
            info = subprocess.run(
                ["bsdtar", "-xOf", str(package_file), ".PKGINFO"],
                capture_output=True,
                text=True,
                timeout=120,
            ).stdout
            name = ""
            for line in info.splitlines():
                if line.startswith("pkgname = "):
                    name = line.removeprefix("pkgname = ").strip()
                    break
            if name:
                for base, metadata in packages.items():
                    if name in metadata.packages:
                        providers.add(base)
                        break
                else:
                    providers.add(name)

    if external_file and external_file.is_file():
        for raw in external_file.read_text(encoding="utf-8", errors="replace").splitlines():
            line = raw.split("#", 1)[0].strip()
            if line and (line == soname or line == normalized):
                providers.add("external")

    return sorted(providers)


def find_dependents(packages: dict, provider_bases: list[str]) -> list[str]:
    graph = graph_consumers(packages)
    dependents: set[str] = set()
    for base in provider_bases:
        for name in {base} | set(packages.get(base).providers if base in packages else ()):
            dependents |= graph.get(name, set())
    dependents.discard("")
    return sorted(dependents)


MAX_TREE_LINES = 60


def failure_chain(
    packages: dict, base: str, highlighted: list[str] | None = None
) -> list[str]:
    """Direct dependencies of *base*, annotated with their internal provider.

    The tree is capped: ffmpeg-full has ~140 direct dependencies and a full
    dump buries the two lines that matter.
    """
    metadata = packages.get(base)
    if metadata is None:
        return []
    highlighted = highlighted or []
    internal: list[str] = []
    external: list[str] = []
    for dependency in sorted(metadata.all_dependencies()):
        name = dependency_name(str(dependency))
        provider = ""
        for candidate, candidate_metadata in packages.items():
            if name in candidate_metadata.providers:
                provider = candidate
                break
        if provider:
            marker = "  <-- PROVIDER under investigation" if provider in highlighted else ""
            internal.append(f"{base} -> {name} (provided by {provider}){marker}")
        else:
            external.append(f"{base} -> {name} (external)")
    if len(external) > MAX_TREE_LINES:
        external = external[:MAX_TREE_LINES] + [
            f"... and {len(external) - MAX_TREE_LINES} more external dependencies"
        ]
    return internal + external


def collect_environment() -> list[str]:
    lines = [f"analyzed_at = {utc_now()}"]
    commands = (
        ("uname", ["uname", "-a"]),
        ("os_release", ["sh", "-c", "grep -E '^(NAME|VERSION|ID|PRETTY_NAME)=' /etc/os-release 2>/dev/null"]),
        ("gcc", ["sh", "-c", "gcc --version 2>/dev/null | head -n1"]),
        ("python", ["sh", "-c", "python3 --version 2>/dev/null"]),
        ("ccache", ["sh", "-c", "ccache -s 2>/dev/null | head -n 12"]),
    )
    for label, command in commands:
        try:
            result = subprocess.run(command, capture_output=True, text=True, timeout=30)
        except (OSError, subprocess.TimeoutExpired):
            continue
        output = (result.stdout or result.stderr).strip()
        if output:
            lines.append(f"# {label}")
            lines.extend(output.splitlines())
    return lines


def render(failure: dict) -> str:
    line = "".join(["-"] * 20)
    lines = ["Failure", line, f"Package: {failure['package']}", f"Stage:   {failure['stage']}"]
    lines.append(f"Category: {failure['category']}")
    lines.append(f"Root cause: {failure['root_cause'] or 'unclassified'}")
    if failure.get("providers"):
        lines.append(f"Provider: {', '.join(failure['providers'])}")
    if failure.get("missing_libraries"):
        lines.append(f"Missing libraries: {', '.join(failure['missing_libraries'])}")
    if failure.get("abi_mismatch"):
        lines.append("Detected ABI mismatch: YES")
    if failure.get("dependents"):
        lines.append(f"Dependents: {', '.join(failure['dependents'])}")
    if failure.get("failing_function"):
        lines.append(f"Failing function: {failure['failing_function']}()")
    lines.append(f"Recommended action: {failure['recommended_action']}")
    lines.append(f"Auto-fix: {failure['auto_fix']['level']} ({failure['auto_fix']['reason']})")
    lines.append(f"Confidence: {failure['confidence']}")
    for finding in failure.get("matched_rules", [])[:3]:
        lines.append(
            f"Rule: {finding['id']} ({finding['category']}, {finding['confidence']})"
        )
    if failure.get("evidence"):
        lines.append("Evidence:")
        for item in failure["evidence"][:5]:
            lines.append(f"  {item}")
    return "\n".join(lines)


def write_report_bundle(args: argparse.Namespace, failure: dict, log_lines: list[str]) -> None:
    report_dir = args.report_dir
    report_dir.mkdir(parents=True, exist_ok=True)
    (report_dir / "summary.json").write_text(
        json.dumps(failure, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )

    log_text = "\n".join(log_lines)
    if len(log_text.encode("utf-8", errors="replace")) > MAX_LOG_BYTES:
        log_text = log_text[-MAX_LOG_BYTES:]
        log_text = "[truncated to the last 4 MiB]\n" + log_text
    (report_dir / "failure.log").write_text(log_text + "\n", encoding="utf-8")

    copies = {
        args.plan: "build-plan.json",
        args.changed_files: "changed-files.txt",
        args.timings: "timings.json",
        args.repair_attempts: "repair-attempts.json",
    }
    for source, name in copies.items():
        if source and Path(source).is_file():
            (report_dir / name).write_text(
                Path(source).read_text(encoding="utf-8", errors="replace"), encoding="utf-8"
            )

    (report_dir / "dependency-tree.txt").write_text(
        "\n".join(failure.get("dependency_tree", [])) + "\n", encoding="utf-8"
    )

    metadata = []
    package_dir = args.root / "packages" / args.package
    for name in ("PKGBUILD", ".SRCINFO"):
        path = package_dir / name
        if path.is_file():
            metadata.append(f"# {name}")
            metadata.append(path.read_text(encoding="utf-8", errors="replace").rstrip())
    (report_dir / "package-metadata.txt").write_text("\n".join(metadata) + "\n", encoding="utf-8")

    (report_dir / "environment.txt").write_text(
        "\n".join(collect_environment()) + "\n", encoding="utf-8"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--package", required=True)
    parser.add_argument("--log", type=Path, required=True)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--rules", type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--report-dir", type=Path)
    parser.add_argument("--repository-dir", type=Path)
    parser.add_argument("--provider-index", type=Path, help="unused placeholder for CI parity")
    parser.add_argument("--plan", type=Path)
    parser.add_argument("--changed-files", type=Path)
    parser.add_argument("--timings", type=Path)
    parser.add_argument("--repair-attempts", type=Path)
    parser.add_argument("--stage", default="")
    parser.add_argument("--exit-code", type=int, default=1)
    parser.add_argument("--json", action="store_true", help="print JSON instead of the human report")
    args = parser.parse_args()

    root = args.root.resolve()
    rules_dir = args.rules or root / "scripts" / "data" / "build-errors"
    rules = load_rule_files(rules_dir)
    lines = read_log(args.log)
    if not lines:
        lines = ["<no build log was captured>"]

    hinted_stage = args.stage or detect_stage(lines)
    missing_libraries = collect_missing_libraries(lines)
    findings = classify(lines, rules, hinted_stage, missing_libraries)
    primary = findings[0]["rule"] if findings else None

    packages = load_packages(root)
    fields = extract_fields(primary, lines) if primary else {}

    providers = []
    dependents = []
    for soname in missing_libraries:
        providers.extend(
            resolve_providers(
                soname,
                root,
                packages,
                args.repository_dir,
                root / "scripts" / "data" / "external-sonames.txt",
            )
        )
    providers = sorted(set(providers))
    if providers:
        dependents = find_dependents(packages, [name for name in providers if name in packages])

    failing_function = ""
    for line in lines:
        match = FAILED_FUNCTION.search(line)
        if match:
            failing_function = match.group(1)
            break

    root_cause = ""
    if primary and primary.root_cause:
        try:
            root_cause = primary.root_cause.format(**fields)
        except (KeyError, IndexError, ValueError):
            # A placeholder the extract regex could not fill (for example a
            # conflict line whose package names do not match the pattern):
            # keep the message readable instead of shipping a literal
            # {dependency} template into the issue title.
            root_cause = re.sub(r"\{[a-z_]+\}", "?", primary.root_cause)
    if not root_cause and fields:
        root_cause = ", ".join(f"{key}={value}" for key, value in sorted(fields.items()))

    auto_fix_action = (primary.action if primary else {}) or {}
    level = str(auto_fix_action.get("safe_auto_fix", "none"))
    reason_map = {
        "none": "reporting only; a human must decide",
        "level1": "safe housekeeping, no PKGBUILD change",
        "level2": "validated metadata repair",
        "level3": "requires a rebuild and full validation",
        "level4": "forbidden to automate; a suggested patch is produced instead",
    }
    if level == "none" and primary and primary.category in ("SONAMEError", "RuntimeDependencyError"):
        level = "level3"

    recommended = (auto_fix_action.get("kind") if auto_fix_action else "") or "manual_triage"
    if level == "level3" or level == "level4":
        recommended = f"rebuild {args.package}"
        if providers:
            recommended += f" (provider: {', '.join(providers)})"
        elif missing_libraries:
            recommended += " after refreshing the missing provider"
        recommended += " and re-validate"

    abi_mismatch = bool(missing_libraries and providers)

    failure = {
        "schema": 1,
        "analyzed_at": utc_now(),
        "package": args.package,
        "status": "failed",
        "exit_code": args.exit_code,
        "stage": primary.stage if primary else hinted_stage,
        "detected_stage": hinted_stage,
        "category": primary.category if primary else "BuildError",
        "confidence": primary.confidence if primary else "low",
        "root_cause": root_cause,
        "failing_function": failing_function,
        "missing_libraries": missing_libraries,
        "providers": providers,
        "dependents": dependents,
        "abi_mismatch": abi_mismatch,
        "recommended_action": recommended,
        "auto_fix": {
            "level": level,
            "safe": level in ("level1", "level2"),
            "reason": reason_map.get(level, "unclassified"),
            "retry": bool(auto_fix_action.get("retry", False)),
        },
        "matched_rules": [
            {
                "id": item["rule"].id,
                "category": item["rule"].category,
                "stage": item["rule"].stage,
                "confidence": item["rule"].confidence,
                "summary": item["rule"].summary,
                "source": item["rule"].source,
            }
            for item in findings[:5]
        ],
        "fields": fields,
        "evidence": findings[0]["evidence"] if findings else [],
        "dependency_tree": failure_chain(packages, args.package, providers),
        "log_lines": len(lines),
    }

    payload = json.dumps(failure, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(payload, encoding="utf-8")
    if args.report_dir:
        write_report_bundle(args, failure, lines)

    if args.json:
        sys.stdout.write(payload)
    else:
        print(render(failure))
        if len(findings) > 1:
            print("\nOther candidates: " + ", ".join(item["rule"].id for item in findings[1:5]))
    return


if __name__ == "__main__":
    main()
