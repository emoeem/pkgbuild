#!/usr/bin/env python3
"""Regression tests for scripts/build-dag.py.

The DAG scheduler turns the planner's rebuild set into waves that can run
without a package building against a stale in-repo prerequisite.  Nothing
pinned that behaviour before, so these tests cover the decision itself:
wave order, cycle fallback, slot packing and the prerequisite query that
scripts/wait-for-build-dependencies.sh consumes.

They deliberately shell out to the CLI (the contract build.yml and the wait
script use) and touch no Git repository, so they are safe to run from a
pre-commit hook.
"""
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DAG = ROOT / "scripts" / "build-dag.py"


def add_package(root: Path, name: str, depends=(), provides=()) -> None:
    """Write a minimal but valid packages/<name>/{.SRCINFO,PKGBUILD} pair."""
    directory = root / "packages" / name
    directory.mkdir(parents=True, exist_ok=True)
    lines = [
        f"pkgbase = {name}",
        "\tpkgdesc = test",
        "\tpkgver = 1.0",
        "\tpkgrel = 1",
        "\tarch = x86_64",
        "",
        f"pkgname = {name}",
    ]
    lines += [f"\tprovides = {value}" for value in provides]
    lines += [f"\tdepends = {value}" for value in depends]
    (directory / ".SRCINFO").write_text("\n".join(lines) + "\n", encoding="utf-8")
    (directory / "PKGBUILD").write_text(f"pkgname={name}\npkgver=1.0\npkgrel=1\n", encoding="utf-8")


def add_rebuild_on(root: Path, name: str, *lines: str) -> None:
    """Declare rebuild triggers for packages/<name> like the repository does.

    The declarations are read through scripts/list-rebuild-triggers.sh, so the
    fixture root gets a copy of that parser: the point of these tests is the
    declaration -> graph edge path, not the parsing itself.
    """
    helper = root / "scripts"
    helper.mkdir(exist_ok=True)
    (helper / "list-rebuild-triggers.sh").write_bytes(
        (ROOT / "scripts" / "list-rebuild-triggers.sh").read_bytes()
    )
    (root / "packages" / name / ".rebuild-on").write_text(
        "\n".join(lines) + "\n", encoding="utf-8"
    )


class BuildDagTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "packages").mkdir()
        (self.root / "state").mkdir()

    def tearDown(self):
        self.temp.cleanup()

    def dag(self, *args, expect_success=True, timeout=60):
        completed = subprocess.run(
            [sys.executable, str(DAG), "--root", str(self.root), *args],
            text=True,
            capture_output=True,
            timeout=timeout,
        )
        if expect_success:
            self.assertEqual(completed.returncode, 0, completed.stderr)
        return completed

    def document(self, *args) -> dict:
        completed = self.dag(*args, "--format", "json")
        return json.loads(completed.stdout)

    def wave_sets(self, document: dict) -> list[list[str]]:
        return [sorted(wave["packages"]) for wave in document["waves"]]

    # --- wave order ------------------------------------------------------

    def test_chain_serialises_into_successive_waves(self):
        add_package(self.root, "lib", depends=["toolchain"])
        add_package(self.root, "toolchain")
        add_package(self.root, "app", depends=["lib"])
        document = self.document("--packages", "app,lib,toolchain", "--cpus", "8", "--memory-gb", "16")
        self.assertEqual(self.wave_sets(document), [["toolchain"], ["lib"], ["app"]])
        self.assertEqual(document["counts"]["waves"], 3)
        self.assertEqual(document["topological_order"], ["toolchain", "lib", "app"])

    def test_diamond_packs_independent_work_into_one_wave(self):
        add_package(self.root, "a")
        add_package(self.root, "b")
        add_package(self.root, "d")
        add_package(self.root, "c", depends=["a", "b"])
        add_package(self.root, "e", depends=["d"])
        document = self.document("--packages", "a,b,c,d,e", "--cpus", "8", "--memory-gb", "16")
        self.assertEqual(self.wave_sets(document), [["a", "b", "d"], ["c", "e"]])

    def test_prerequisite_in_a_later_wave_is_never_in_an_earlier_one(self):
        add_package(self.root, "toolchain")
        add_package(self.root, "lib", depends=["toolchain"])
        add_package(self.root, "app", depends=["lib"])
        document = self.document("--packages", "app,lib,toolchain")
        order = document["topological_order"]
        self.assertLess(order.index("toolchain"), order.index("lib"))
        self.assertLess(order.index("lib"), order.index("app"))

    # --- cycles ----------------------------------------------------------

    def test_dependency_cycle_falls_back_to_one_wave_without_hanging(self):
        add_package(self.root, "mutual-a", depends=["mutual-b"])
        add_package(self.root, "mutual-b", depends=["mutual-a"])
        # timeout guards the "spins forever on a cycle" regression.
        document = self.document("--packages", "mutual-a,mutual-b", "--cpus", "8", "--memory-gb", "16")
        self.assertEqual(self.wave_sets(document), [["mutual-a", "mutual-b"]])
        self.assertEqual(document["counts"]["waves"], 1)

    def test_dependency_cycle_is_reported_not_silently_merged(self):
        add_package(self.root, "mutual-a", depends=["mutual-b"])
        add_package(self.root, "mutual-b", depends=["mutual-a"])
        document = self.document("--packages", "mutual-a,mutual-b")
        self.assertEqual(document["cycles"], [["mutual-a", "mutual-b", "mutual-a"]])
        completed = self.dag("--packages", "mutual-a,mutual-b")
        self.assertIn("WARNING: dependency cycle", completed.stdout)
        self.assertIn("mutual-a -> mutual-b -> mutual-a", completed.stdout)

    def test_no_cycle_is_reported_for_an_ordered_selection(self):
        add_package(self.root, "lib", depends=["toolchain"])
        add_package(self.root, "toolchain")
        document = self.document("--packages", "lib,toolchain")
        self.assertEqual(document["cycles"], [])

    # --- .rebuild-on declarations ----------------------------------------

    def test_declared_package_trigger_orders_the_declarer_after_it(self):
        add_package(self.root, "toolchain")
        add_package(self.root, "consumer")
        add_rebuild_on(self.root, "consumer", "package toolchain")
        document = self.document("--packages", "consumer,toolchain", "--cpus", "8", "--memory-gb", "16")
        self.assertEqual(self.wave_sets(document), [["toolchain"], ["consumer"]])
        completed = self.dag("--prerequisites-for", "consumer")
        self.assertEqual(json.loads(completed.stdout), ["toolchain"])

    def test_declared_soname_trigger_resolves_to_its_provider(self):
        # The declaration uses the linker spelling, the .SRCINFO provides the
        # pacman one: both have to resolve to the same provider base.
        add_package(self.root, "foo", provides=["libfoo.so=2-64"])
        add_package(self.root, "consumer")
        add_rebuild_on(self.root, "consumer", "soname libfoo.so.2 foo")
        document = self.document("--packages", "consumer,foo", "--cpus", "8", "--memory-gb", "16")
        self.assertEqual(self.wave_sets(document), [["foo"], ["consumer"]])

    def test_declared_trigger_outside_the_selection_does_not_serialise(self):
        add_package(self.root, "toolchain")
        add_package(self.root, "consumer")
        add_package(self.root, "other")
        add_rebuild_on(self.root, "consumer", "package toolchain")
        document = self.document("--packages", "consumer,other", "--cpus", "8", "--memory-gb", "16")
        self.assertEqual(self.wave_sets(document), [["consumer", "other"]])

    def test_declaration_without_its_parser_fails_instead_of_being_ignored(self):
        add_package(self.root, "toolchain")
        add_package(self.root, "consumer")
        # Same declaration as above, but the parser is not available in this
        # root: the declaration must not be dropped silently.
        (self.root / "packages" / "consumer" / ".rebuild-on").write_text(
            "package toolchain\n", encoding="utf-8"
        )
        completed = self.dag("--packages", "consumer,toolchain", expect_success=False)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("list-rebuild-triggers.sh", completed.stderr + completed.stdout)

    # --- prerequisites ---------------------------------------------------

    def test_prerequisites_for_reports_in_repo_dependencies(self):
        add_package(self.root, "toolchain")
        add_package(self.root, "lib", depends=["toolchain"])
        add_package(self.root, "app", depends=["lib", "glibc"])
        completed = self.dag("--prerequisites-for", "app")
        self.assertEqual(json.loads(completed.stdout), ["lib"])

    def test_prerequisites_for_is_empty_for_a_leaf(self):
        add_package(self.root, "leaf", depends=["glibc"])
        completed = self.dag("--prerequisites-for", "leaf")
        self.assertEqual(json.loads(completed.stdout), [])

    # --- slot packing ----------------------------------------------------

    def test_packing_honours_max_parallel_jobs(self):
        add_package(self.root, "x")
        add_package(self.root, "y")
        add_package(self.root, "z")
        document = self.document("--packages", "x,y,z", "--cpus", "32", "--memory-gb", "64", "--max-parallel-jobs", "1")
        self.assertEqual(document["counts"]["parallel_jobs_per_slot"], 1)
        for wave in document["waves"]:
            for slot in wave["slots"]:
                self.assertLessEqual(len(slot["packages"]), 1)

    def test_runner_capacity_drives_slot_width(self):
        for name in ("x", "y", "z"):
            add_package(self.root, name)
        document = self.document("--packages", "x,y,z", "--cpus", "8", "--memory-gb", "16")
        self.assertEqual(document["counts"]["parallel_jobs_per_slot"], 2)
        self.assertEqual(document["counts"]["ram_slots"], 4)

    # --- plan input ------------------------------------------------------

    def test_plan_input_limits_the_dag_to_the_rebuild_set(self):
        add_package(self.root, "toolchain")
        add_package(self.root, "lib", depends=["toolchain"])
        add_package(self.root, "untouched")
        plan = self.root / "plan.json"
        plan.write_text(json.dumps({"rebuild": ["lib", "toolchain"]}), encoding="utf-8")
        document = self.document("--plan", str(plan))
        self.assertEqual(self.wave_sets(document), [["toolchain"], ["lib"]])
        self.assertNotIn("untouched", document["topological_order"])

    def test_empty_plan_builds_nothing(self):
        add_package(self.root, "toolchain")
        plan = self.root / "plan.json"
        plan.write_text(json.dumps({"rebuild": []}), encoding="utf-8")
        document = self.document("--plan", str(plan))
        self.assertEqual(document["waves"], [])
        self.assertEqual(document["counts"]["packages"], 0)

    # --- weights ---------------------------------------------------------

    def test_measured_timing_overrides_declared_weights(self):
        add_package(self.root, "heavy")
        history = self.root / "state" / "timing-history.jsonl"
        history.write_text(
            json.dumps(
                {
                    "package": "heavy",
                    "total_seconds": 4000,
                    "resources": {"cpu_seconds": 3600, "memory_peak_bytes": 16 * 1024**3},
                }
            )
            + "\n",
            encoding="utf-8",
        )
        document = self.document("--packages", "heavy", "--timing-history", str(history))
        weight = document["weights"]["heavy"]
        self.assertEqual(weight["source"], "measured")
        self.assertEqual(weight["cpu"], 3)
        self.assertEqual(weight["ram"], 3)
        self.assertGreater(document["estimated_makespan_seconds"], 0)

    def test_missing_timing_history_falls_back_to_the_declared_table(self):
        add_package(self.root, "plain")
        document = self.document("--packages", "plain")
        self.assertEqual(document["weights"]["plain"]["source"], "declared")
        self.assertEqual(document["estimated_makespan_seconds"], 0.0)

    # --- unknown input ---------------------------------------------------

    def test_unknown_package_is_rejected_not_silently_ignored(self):
        add_package(self.root, "known")
        completed = self.dag("--packages", "known,does-not-exist", expect_success=False)
        self.assertNotEqual(completed.returncode, 0)
        self.assertIn("does-not-exist", completed.stderr + completed.stdout)


if __name__ == "__main__":
    unittest.main()
