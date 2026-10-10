"""Shared PKGBUILD / .SRCINFO metadata and dependency-graph helpers.

This module is the single source of truth for how this repository turns
packages/*/PKGBUILD directories into a build graph.  select-packages.py,
build-planner.py, build-dag.py and analyze-build-failure.py all import it, so
"which packages does this change affect" has exactly one implementation and
one set of semantics.

Graph semantics (unchanged from the behaviour the integration tests pin down):

* every pkgname and every provides entry of a package base is a provider of
  that base (covers split packages and virtual packages);
* depends, makedepends and checkdepends all create a consumer edge, because
  rebuilding a library or a compile-time tool can change the ABI of
  everything that links or builds against it;
* version constraints (foo>=1.2) are normalised to the bare name;
* config/** is infrastructure: changing it rebuilds every package;
* changes that only touch the CI pipeline / documentation select nothing;
* packages/<dir>/.rebuild-on declares rebuild triggers that no .SRCINFO relation
  can express (a package linking a library whose provider is outside the
  repository, or a coupling discovered by maintenance).  A `package <name>`
  declaration makes <name> reuse the declarer, and a `soname <soname>
  <provider>` declaration follows both the provider package and the SONAME.
  scripts/list-rebuild-triggers.sh is the single parser for those files, and
  this module is the single place that turns them into graph edges, so
  build-planner.py and select-packages.py cannot disagree about them.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
from dataclasses import dataclass, field, replace
from pathlib import Path

PACKAGE_NAME_PATTERN = re.compile(r"^[A-Za-z0-9@._+-]+$")
DEPENDENCY_OPERATOR_PATTERN = re.compile(r"^([^<>=]+)(?:[<>=].*)?$")
#: pacman spells a SONAME provide/require as "libfoo.so=2-64"; it is an exact
#: relation, not a version constraint, so it must not be split at the "=".
SONAME_RELATION_PATTERN = re.compile(r"^.*[.]so=[0-9][0-9.]*(?:-[0-9]+)?$")

#: Paths that change the toolchain/environment every package is built with.
INFRASTRUCTURE_PATHS = ("config/",)

#: The one config/ file that must not trigger a rebuild of everything: the
#: update source registry only records who refreshes a package, so editing it
#: costs nothing.  See check-package-manifests.py.
UPDATE_SOURCE_REGISTRY = "config/package-updates.txt"

#: Paths that affect the pipeline itself but never a produced package.
PIPELINE_PATHS = (
    ".github/",
    "docs/",
    "tests/",
    "manage.sh",
    "README.md",
    "OPTIMIZATION-REVIEW.md",
)


#: Declaration file listing the rebuild triggers .SRCINFO cannot express.
REBUILD_ON_FILENAME = ".rebuild-on"

#: The single parser for those declarations (shared with the CI soname checks).
REBUILD_TRIGGER_HELPER = Path("scripts/list-rebuild-triggers.sh")


class SourceInfoError(RuntimeError):
    """A package directory has missing or unparsable metadata."""


@dataclass(frozen=True)
class PackageMetadata:
    """Everything the build graph needs to know about one package base."""

    base: str
    directory: str
    path: Path
    packages: tuple[str, ...] = ()
    provides: tuple[str, ...] = ()
    depends: tuple[str, ...] = ()
    makedepends: tuple[str, ...] = ()
    checkdepends: tuple[str, ...] = ()
    arch: tuple[str, ...] = ()
    pkgver: str = ""
    pkgrel: str = ""
    #: Rebuild triggers declared in packages/<dir>/.rebuild-on: package names
    #: (for `package <name>`) plus the SONAME and its provider (for
    #: `soname <soname> <provider>`).  Populated by load_packages().
    rebuild_on: tuple[str, ...] = ()

    @property
    def version(self) -> str:
        if self.pkgver and self.pkgrel:
            return f"{self.pkgver}-{self.pkgrel}"
        return self.pkgver or self.pkgrel

    @property
    def providers(self) -> frozenset[str]:
        """Names that can satisfy a dependency on this package base."""
        return frozenset(self.packages) | frozenset(self.provides)

    def all_dependencies(self) -> frozenset[str]:
        return (
            frozenset(self.depends)
            | frozenset(self.makedepends)
            | frozenset(self.checkdepends)
        )


def dependency_name(dependency: str) -> str:
    """Normalise a dependency relation to the name that identifies it.

    foo>=1.2 -> foo, but libfoo.so=2-64 is kept verbatim: it is a SONAME
    relation whose "=" is part of the name, and truncating it to "libfoo.so"
    silently disconnects every consumer of a shared library from its provider.
    """
    if SONAME_RELATION_PATTERN.match(dependency):
        return dependency
    match = DEPENDENCY_OPERATOR_PATTERN.match(dependency)
    return match.group(1) if match else dependency


def normalized_soname(relation: str) -> str:
    """libfoo.so=2-64 -> libfoo.so.2 (the spelling an ELF NEEDED entry uses)."""
    match = re.fullmatch(r"(.*[.]so)=([0-9][0-9.]*)(?:-[0-9]+)?", relation)
    if not match:
        return relation
    return f"{match.group(1)}.{match.group(2)}"


def _relation_values(block: list[str], key: str) -> tuple[str, ...]:
    prefix = f"{key} = "
    values = []
    for line in block:
        stripped = line.lstrip("\t ")
        if not line.startswith(("\t", " ")) or not stripped.startswith(prefix):
            continue
        values.append(stripped[len(prefix) :].strip())
    return tuple(values)


def parse_srcinfo(path: Path) -> PackageMetadata:
    """Parse one .SRCINFO into PackageMetadata.

    The parser mirrors makepkg's layout: top-level "key = value" lines
    describe the package base, everything after the first "pkgname =" is
    inside a package section and is indented.
    """
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:  # pragma: no cover - defensive
        raise SourceInfoError(f"cannot read {path}: {error}") from error

    base = ""
    packages: list[str] = []
    pkgver = ""
    pkgrel = ""
    arch: tuple[str, ...] = ()
    current: list[str] = []
    sections: list[list[str]] = []
    in_package = False

    for line in text.splitlines():
        if line.startswith("pkgbase = "):
            base = line.removeprefix("pkgbase = ").strip()
            continue
        if line.startswith("pkgname = "):
            if current:
                sections.append(current)
            current = []
            packages.append(line.removeprefix("pkgname = ").strip())
            in_package = True
            continue
        # makepkg indents package-base keys with a tab as well, so the
        # positional rule (before the first pkgname) is what separates base
        # metadata from per-package relations.
        if not in_package:
            key, separator, value = line.strip().partition(" = ")
            if separator:
                if key == "pkgver":
                    pkgver = value.strip()
                elif key == "pkgrel":
                    pkgrel = value.strip()
                elif key == "arch":
                    arch = tuple(part for part in value.split() if part)
        current.append(line)
    if current:
        sections.append(current)

    if not packages:
        raise SourceInfoError(f"{path} declares no pkgname")

    provides: list[str] = []
    depends: list[str] = []
    makedepends: list[str] = []
    checkdepends: list[str] = []
    for section in sections:
        provides.extend(_relation_values(section, "provides"))
        depends.extend(_relation_values(section, "depends"))
        makedepends.extend(_relation_values(section, "makedepends"))
        checkdepends.extend(_relation_values(section, "checkdepends"))

    directory = path.parent.name
    return PackageMetadata(
        base=base or directory,
        directory=directory,
        path=path.parent,
        packages=tuple(dict.fromkeys(packages)),
        provides=tuple(dict.fromkeys(provides)),
        depends=tuple(dict.fromkeys(depends)),
        makedepends=tuple(dict.fromkeys(makedepends)),
        checkdepends=tuple(dict.fromkeys(checkdepends)),
        arch=arch,
        pkgver=pkgver,
        pkgrel=pkgrel,
    )


def package_dirs(root: Path) -> list[Path]:
    """Every packages/<name> directory containing a PKGBUILD."""
    packages = root / "packages"
    if not packages.is_dir():
        return []
    return sorted(
        path.parent
        for path in packages.glob("*/PKGBUILD")
        if path.is_file() and PACKAGE_NAME_PATTERN.fullmatch(path.parent.name)
    )


def available_packages(root: Path) -> list[str]:
    return [path.name for path in package_dirs(root)]


def declared_dependencies(root: Path) -> dict[str, set[str]]:
    """package directory name -> rebuild triggers declared in its .rebuild-on.

    The declarations are parsed by scripts/list-rebuild-triggers.sh, the same
    parser the CI soname checks use, so a declaration cannot mean one thing
    while selecting packages and another while scheduling them.  Roots without
    that helper (test fixtures) simply have no declarations.
    """
    helper = root / REBUILD_TRIGGER_HELPER
    if not helper.is_file():
        # Declarations without their parser must fail loudly: silently dropping
        # them is how a package ends up built against a stale prerequisite.
        declarations = sorted((root / "packages").glob(f"*/{REBUILD_ON_FILENAME}"))
        if declarations:
            raise SourceInfoError(
                f"{len(declarations)} {REBUILD_ON_FILENAME} declaration(s) found but "
                f"{REBUILD_TRIGGER_HELPER} is missing; the rebuild graph would ignore them"
            )
        return {}
    completed = subprocess.run(
        ["bash", str(helper), str(root / "packages")],
        capture_output=True,
        text=True,
        check=False,
    )
    if completed.returncode != 0:
        raise SourceInfoError(
            completed.stderr.strip()
            or f"{REBUILD_TRIGGER_HELPER} exited with status {completed.returncode}"
        )
    declared: dict[str, set[str]] = {}
    for line in completed.stdout.splitlines():
        fields = line.split("\t")
        kind = fields[0] if fields else ""
        directory = fields[1] if len(fields) > 1 else ""
        if kind == "package" and len(fields) == 3:
            triggers = {fields[2]}
        elif kind == "soname" and len(fields) == 4:
            triggers = {fields[2], fields[3]}
        else:
            raise SourceInfoError(
                f"unexpected {REBUILD_ON_FILENAME} entry: {line!r}"
            )
        declared.setdefault(directory, set()).update(trigger for trigger in triggers if trigger)
    return declared


def load_packages(root: Path) -> dict[str, PackageMetadata]:
    """Map directory name -> metadata, skipping directories without .SRCINFO."""
    declared = declared_dependencies(root)
    result: dict[str, PackageMetadata] = {}
    for directory in package_dirs(root):
        srcinfo = directory / ".SRCINFO"
        if not srcinfo.is_file():
            continue
        metadata = parse_srcinfo(srcinfo)
        triggers = declared.get(directory.name)
        if triggers:
            metadata = replace(metadata, rebuild_on=tuple(sorted(triggers)))
        result[directory.name] = metadata
    return result


def dependency_graph(
    packages: dict[str, PackageMetadata],
) -> dict[str, set[str]]:
    """Map every dependency name to the package bases that consume it."""
    provider_to_consumers: dict[str, set[str]] = {}
    for metadata in packages.values():
        for provided in metadata.providers:
            provider_to_consumers.setdefault(provided, set())
        for dependency in metadata.all_dependencies():
            name = dependency_name(dependency)
            provider_to_consumers.setdefault(name, set()).add(metadata.directory)
    return provider_to_consumers


def graph_consumers(
    packages: dict[str, PackageMetadata],
) -> dict[str, set[str]]:
    """Provider name -> consuming bases, including every base name itself."""
    graph = dependency_graph(packages)
    for base, metadata in packages.items():
        graph.setdefault(base, set())
        for provided in metadata.providers:
            graph.setdefault(provided, set())
        # .rebuild-on turns a declaration into a consumer edge: whoever
        # provides the declared trigger pulls the declarer back into the
        # selection, exactly like an .SRCINFO relation would.
        for owner in declaration_providers(metadata, packages):
            graph.setdefault(owner, set()).add(base)
    return graph


def provider_map(packages: dict[str, PackageMetadata]) -> dict[str, set[str]]:
    """Map every provider name to the package bases that provide it."""
    providers: dict[str, set[str]] = {}
    for base, metadata in packages.items():
        for provided in metadata.providers:
            providers.setdefault(provided, set()).add(base)
            # Also index the linker spelling (libfoo.so=2-64 -> libfoo.so.2),
            # so a lookup by bare SONAME finds the provider.
            soname = normalized_soname(provided)
            if soname != provided:
                providers.setdefault(soname, set()).add(base)
    return providers


def declaration_providers(
    metadata: PackageMetadata, packages: dict[str, PackageMetadata]
) -> set[str]:
    """In-repo bases that a package's .rebuild-on triggers resolve to.

    Resolving to base names (instead of keying edges by the trigger string)
    keeps the graph independent of how the trigger is spelled: a SONAME
    declaration matches the provider whether the graph carries the pacman
    spelling (libfoo.so=2-64) or the linker one (libfoo.so.2).  Triggers whose
    provider is outside this repository resolve to nothing here; an external
    dependency changing is the drift checker's job, not the build graph's.
    """
    providers = provider_map(packages)
    result: set[str] = set()
    for trigger in metadata.rebuild_on:
        if trigger in packages:
            result.add(trigger)
        result.update(providers.get(trigger, set()))
    result.discard(metadata.directory)
    return result


def in_repo_dependencies(
    base: str, packages: dict[str, PackageMetadata]
) -> set[str]:
    """Package bases in this repository that *base* depends on.

    Note the direction: this asks which bases *provide* something base needs,
    not which bases share a dependency.  The consumer graph answers the
    opposite question, and using it here silently inverts the build order
    (a package was scheduled before the dependency it needs).
    """
    metadata = packages.get(base)
    if metadata is None:
        return set()
    providers = provider_map(packages)
    result: set[str] = set()
    for dependency in metadata.all_dependencies():
        name = dependency_name(str(dependency))
        for provider in providers.get(name, set()):
            if provider != base:
                result.add(provider)
    # A declared trigger is also an ordering constraint: the declarer has to
    # be rebuilt *after* the thing it declares, never in the same wave.
    result |= declaration_providers(metadata, packages)
    return result


def dependency_map(
    packages: dict[str, PackageMetadata],
) -> dict[str, set[str]]:
    """base -> in-repo prerequisites, for every package base."""
    return {base: in_repo_dependencies(base, packages) for base in packages}


def transitive_closure(
    selected: set[str],
    packages: dict[str, PackageMetadata],
    graph: dict[str, set[str]],
) -> set[str]:
    """Propagate the selection through the provider graph until it stops."""
    available = set(packages)
    result = {name for name in selected if name in available}
    changed = True
    while changed:
        changed = False
        for base in list(result):
            metadata = packages.get(base)
            names = {base}
            if metadata is not None:
                names |= set(metadata.providers)
            for name in names:
                for consumer in graph.get(name, set()):
                    if consumer in available and consumer not in result:
                        result.add(consumer)
                        changed = True
    return result


def git_environment() -> dict[str, str]:
    """The current environment without inherited GIT_* variables.

    Git exports GIT_DIR / GIT_WORK_TREE / GIT_INDEX_FILE to the processes it
    starts (hooks), and CI providers and other projects do the same.  Those
    variables outrank `cwd=`, so a subprocess that means to inspect the
    checkout at *root* would silently read a different repository.  Every git
    call in this module goes through here; scripts/run-static-checks.sh unsets
    the same variables for the shell side of the pipeline.
    """
    return {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}


def changed_files(root: Path, before: str, after: str) -> list[str]:
    """Files touched between before and after, with a safe fallback."""
    exists = (
        subprocess.run(
            ["git", "cat-file", "-e", f"{before}^{{commit}}"],
            cwd=root,
            env=git_environment(),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode
        == 0
    )
    if exists or not after:
        diff_args = ["git", "diff", "--name-only", before, after or "HEAD"]
    else:
        # Force-pushed histories make github.event.before unavailable in a
        # fresh checkout.  Fall back to the new commit's tree rather than
        # failing package selection altogether.
        diff_args = [
            "git",
            "diff-tree",
            "--root",
            "--no-commit-id",
            "--name-only",
            "-r",
            after,
        ]
    result = subprocess.run(
        diff_args,
        cwd=root,
        env=git_environment(),
        check=True,
        capture_output=True,
        text=True,
    )
    return [line for line in result.stdout.splitlines() if line]


@dataclass
class ChangeImpact:
    """How a set of changed paths maps onto the build graph."""

    direct: set[str] = field(default_factory=set)
    overlays: set[str] = field(default_factory=set)
    infrastructure: list[str] = field(default_factory=list)
    pipeline: list[str] = field(default_factory=list)
    ignored: list[str] = field(default_factory=list)
    reasons: dict[str, list[str]] = field(default_factory=dict)

    @property
    def infrastructure_changed(self) -> bool:
        return bool(self.infrastructure)

    def explain(self, base: str, reason: str) -> None:
        bucket = self.reasons.setdefault(base, [])
        if reason not in bucket:
            bucket.append(reason)


def classify_changes(
    root: Path, paths: list[str], packages: dict[str, PackageMetadata]
) -> ChangeImpact:
    """Map changed file paths to package bases, overlays and infrastructure."""
    impact = ChangeImpact()
    available = set(packages)
    for path in paths:
        parts = path.split("/")
        if path.startswith(INFRASTRUCTURE_PATHS):
            if path == UPDATE_SOURCE_REGISTRY:
                # A bookkeeping edit is not an environment change: keeping it
                # out of `infrastructure` is what makes "add a package to the
                # registry" stop costing a full rebuild.
                impact.ignored.append(path)
                continue
            impact.infrastructure.append(path)
            continue
        if len(parts) >= 3 and parts[0] == "packages" and parts[1] in available:
            impact.direct.add(parts[1])
            impact.explain(parts[1], f"direct: {path}")
            continue
        if len(parts) == 3 and parts[0:2] == ["scripts", "overlays"]:
            overlay_base = parts[2].removesuffix(".sh")
            if overlay_base in available:
                impact.overlays.add(overlay_base)
                impact.explain(overlay_base, f"overlay: {path}")
                continue
        if path.startswith(PIPELINE_PATHS):
            impact.pipeline.append(path)
        else:
            impact.ignored.append(path)
    return impact


def topological_order(
    bases: list[str], packages: dict[str, PackageMetadata]
) -> list[str]:
    """Order bases so providers come before their consumers when possible."""
    selected = set(bases)
    prerequisites = dependency_map(packages)
    dependencies: dict[str, set[str]] = {
        base: {name for name in prerequisites.get(base, set()) if name in selected}
        for base in selected
    }
    ordered: list[str] = []
    remaining = {name: set(deps) for name, deps in dependencies.items()}
    while remaining:
        ready = sorted(name for name, deps in remaining.items() if not deps)
        if not ready:
            # Dependency cycle inside the selection: emit the rest in a stable
            # order instead of looping forever.
            ordered.extend(sorted(remaining))
            break
        for name in ready:
            ordered.append(name)
            del remaining[name]
        for deps in remaining.values():
            deps.difference_update(ready)
    return ordered


def dumps(value: object) -> str:
    return json.dumps(value, separators=(",", ":"), sort_keys=False)
