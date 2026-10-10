#!/usr/bin/env python3
"""Regression tests for the build failure analyzer and the rule library.

These pin the properties that make the analyzer worth having: a known failure
is classified without a human reading the log, the root cause names the *cause*
(a vanished SONAME) rather than its symptom (a "cannot find -l" linker error),
and an unknown failure is reported as unknown instead of being forced into a
category.
"""
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "lib"))

SPEC = importlib.util.spec_from_file_location("analyzer", ROOT / "scripts/analyze-build-failure.py")
ANALYZER = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(ANALYZER)

from errorrules import RuleError, load_rule_files, load_yaml  # noqa: E402
from pkgbuild_lib import load_packages  # noqa: E402

RULES_DIR = ROOT / "scripts" / "data" / "build-errors"


def package_root(directory: Path, packages):
    """Create a minimal repository tree: (name, provides, depends)."""
    for name, provides, depends in packages:
        path = directory / "packages" / name
        path.mkdir(parents=True)
        lines = [f"pkgbase = {name}", "\tpkgver = 1.0", "\tpkgrel = 1", "\tarch = x86_64", "", f"pkgname = {name}"]
        lines += [f"\tprovides = {value}" for value in provides]
        lines += [f"\tdepends = {value}" for value in depends]
        (path / ".SRCINFO").write_text("\n".join(lines) + "\n", encoding="utf-8")
        (path / "PKGBUILD").write_text(f"pkgname={name}\n", encoding="utf-8")


class RuleLibraryTests(unittest.TestCase):
    def test_rules_load_and_cover_the_category_taxonomy(self):
        rules = load_rule_files(RULES_DIR)
        self.assertGreaterEqual(len(rules), 40)
        categories = {rule.category for rule in rules}
        expected = {
            "EnvironmentError",
            "DependencyError",
            "SourceError",
            "PKGBuildError",
            "PatchError",
            "CompilerError",
            "LinkerError",
            "RuntimeDependencyError",
            "SONAMEError",
            "RepositoryError",
            "CacheError",
            "CIError",
            "NetworkError",
            "TestFailure",
            "PackagingError",
        }
        self.assertTrue(expected <= categories, sorted(expected - categories))
        ids = [rule.id for rule in rules]
        self.assertEqual(len(ids), len(set(ids)), "rule ids must be unique")

    def test_a_malformed_rule_file_is_fatal_not_silently_skipped(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            (directory / "broken.yaml").write_text("rules:\n  - id: x\n    category: Nope\n", encoding="utf-8")
            with self.assertRaises(RuleError):
                load_rule_files(directory)

    def test_duplicate_rule_ids_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            body = "rules:\n  - id: same\n    category: BuildError\n    stage: build\n    patterns:\n      - \"x\"\n"
            (directory / "a.yaml").write_text(body, encoding="utf-8")
            (directory / "b.yaml").write_text(body, encoding="utf-8")
            with self.assertRaises(RuleError):
                load_rule_files(directory)

    def test_the_yaml_subset_parser_handles_the_rule_schema(self):
        document = load_yaml(
            "rules:\n"
            "  - id: demo\n"
            "    category: BuildError\n"
            "    stage: build\n"
            "    confidence: high\n"
            "    patterns:\n"
            "      - \"a # b\"\n"
            "      - 42\n"
            "    action:\n"
            "      retry: true\n"
        )
        rule = document["rules"][0]
        self.assertEqual(rule["id"], "demo")
        self.assertEqual(rule["patterns"], ["a # b", 42])
        self.assertIs(rule["action"]["retry"], True)


class ClassifierTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        package_root(
            self.root,
            [
                ("openapv", ["liboapv.so=2-64"], []),
                ("mpv-emo", [], ["liboapv.so=2-64"]),
                ("ffmpeg-full", [], ["liboapv.so=2-64"]),
            ],
        )
        self.rules = load_rule_files(RULES_DIR)
        self.packages = load_packages(self.root)

    def tearDown(self):
        self.temporary.cleanup()

    def classify(self, log_text):
        lines = log_text.strip().splitlines()
        missing = ANALYZER.collect_missing_libraries(lines)
        findings = ANALYZER.classify(lines, self.rules, ANALYZER.detect_stage(lines), missing)
        return findings, missing

    def test_soname_drift_outranks_its_downstream_linker_error(self):
        findings, missing = self.classify(
            "==> Starting build()...\n"
            "/usr/bin/ld: warning: liboapv.so.2, needed by libavcodec.so, not found\n"
            "/usr/bin/ld: cannot find -loapv\n"
            "collect2: error: ld returned 1 exit status\n"
            "==> ERROR: A failure occurred in build().\n"
        )
        self.assertEqual(missing, ["liboapv.so.2"])
        self.assertEqual(findings[0]["rule"].id, "soname-missing")
        self.assertEqual(findings[0]["rule"].category, "SONAMEError")

    def test_provider_and_dependents_are_resolved_from_the_repository(self):
        providers = ANALYZER.resolve_providers("liboapv.so.2", self.root, self.packages, None, None)
        self.assertEqual(providers, ["openapv"])
        dependents = ANALYZER.find_dependents(self.packages, providers)
        self.assertEqual(dependents, ["ffmpeg-full", "mpv-emo"])

    def test_extracted_fields_and_root_cause_are_filled_in(self):
        lines = ["undefined reference to 'avcodec_send_packet'", "==> ERROR: A failure occurred in build()."]
        findings = ANALYZER.classify(lines, self.rules, "link", [])
        rule = findings[0]["rule"]
        self.assertEqual(rule.category, "LinkerError")
        fields = ANALYZER.extract_fields(rule, lines)
        self.assertEqual(fields.get("symbol"), "avcodec_send_packet")
        self.assertIn("avcodec_send_packet", rule.root_cause.format(**fields))

    def test_representative_failures_map_to_the_right_category(self):
        cases = {
            "error: 'cstdint' file not found\nfatal error: cstdint: No such file or directory": "CompilerError",
            "==> Validating source files with sha256sums...\n    demo.tar.gz ... FAILED\ndid not pass the validity check": "SourceError",
            "cc1plus: error: Cannot allocate memory\nvirtual memory exhausted": "EnvironmentError",
            "ERROR: No space left on device": "EnvironmentError",
            "Package 'lensfun' not found\nmeson.build:10:0: ERROR: Dependency \"lensfun\" not found": "DependencyError",
            "==> ERROR: A failure occurred in check()\nFAILED (failures=3)\nTests failed": "TestFailure",
            "curl: (28) Operation too slow. Less than 1 bytes/sec": "NetworkError",
            "#error -- unsupported GNU version! gcc versions later than 14 are not supported": "CompilerError",
            "Hunk #1 FAILED at 10.\ncan't find file to patch": "PatchError",
            "error[E0425]: cannot find value\nSIGABRT\n==> ERROR: A failure occurred in build().": "CompilerError",
            "duplicate SONAME liboapv.so.1: openapv and legacy-openapv": "RepositoryError",
        }
        for log_text, expected in cases.items():
            with self.subTest(expected=expected, log=log_text.splitlines()[0]):
                findings, _ = self.classify(log_text)
                self.assertTrue(findings, "no rule matched")
                self.assertEqual(findings[0]["rule"].category, expected)

    def test_an_unknown_failure_is_reported_as_unclassified(self):
        findings, _ = self.classify("something entirely unexpected happened")
        self.assertEqual(findings, [])

    def test_stage_detection_follows_the_last_makepkg_banner(self):
        lines = [
            "==> Starting prepare()...",
            "==> Starting build()...",
            "==> Starting package()...",
        ]
        self.assertEqual(ANALYZER.detect_stage(lines), "package")


class ReportBundleTests(unittest.TestCase):
    def test_report_bundle_contains_the_documented_files(self):
        with tempfile.TemporaryDirectory() as temporary:
            work = Path(temporary)
            root = work / "repo"
            package_root(root, [("demo", [], [])])
            log = work / "build.log"
            log.write_text(
                "==> Starting build()...\n"
                "fatal error: missing.h: No such file or directory\n"
                "==> ERROR: A failure occurred in build().\n",
                encoding="utf-8",
            )
            plan = work / "plan.json"
            plan.write_text("{}\n", encoding="utf-8")
            timings = work / "timings.json"
            timings.write_text("{}\n", encoding="utf-8")
            report = work / "build-report"

            argv = [
                "analyze-build-failure.py",
                "--package", "demo",
                "--log", str(log),
                "--root", str(root),
                "--rules", str(RULES_DIR),
                "--report-dir", str(report),
                "--plan", str(plan),
                "--timings", str(timings),
            ]
            original = sys.argv
            sys.argv = argv
            try:
                ANALYZER.main()
            finally:
                sys.argv = original

            for name in (
                "summary.json",
                "failure.log",
                "dependency-tree.txt",
                "environment.txt",
                "package-metadata.txt",
                "build-plan.json",
                "timings.json",
            ):
                self.assertTrue((report / name).is_file(), f"missing {name}")
            summary = json.loads((report / "summary.json").read_text(encoding="utf-8"))
            self.assertEqual(summary["package"], "demo")
            self.assertEqual(summary["category"], "CompilerError")
            self.assertEqual(summary["fields"].get("header"), "missing.h")


if __name__ == "__main__":
    unittest.main()
