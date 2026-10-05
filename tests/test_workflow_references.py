#!/usr/bin/env python3
"""Every script a workflow or the TUI invokes must be tracked by git.

A workflow that calls scripts/foo.sh only works once foo.sh is committed: CI
checks out the commit, not the working tree. This regression test exists
because build.yml referenced two helpers (generate-abi-manifest.sh and
write-back-pkgrel.sh) that were only present in the working tree, so the
release job failed at runtime with no local symptom.
"""
import re
import subprocess
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

REFERENCE = re.compile(r"(?:source/|/workspace/)?(scripts/[A-Za-z0-9._/-]+)")

SKIP_EXACT = {
    "scripts/",
    "scripts/lib",
    "scripts/data",
    "scripts/overlays",
    "scripts/data/build-errors",
}


def tracked_paths() -> set:
    result = subprocess.run(
        ["git", "ls-files"], cwd=ROOT, check=True, capture_output=True, text=True
    )
    return set(result.stdout.splitlines())


def referenced_paths():
    sources = sorted((ROOT / ".github/workflows").glob("*.yml")) + [ROOT / "manage.sh"]
    for source in sources:
        text = source.read_text(encoding="utf-8", errors="replace")
        for match in REFERENCE.finditer(text):
            # A match followed by a backslash belongs to a shell/regex-escaped
            # path such as scripts/create-repository\.sh inside a pattern; the
            # plain reference elsewhere in the same file is what matters.
            if text[match.end() : match.end() + 1] == "\\":
                continue
            candidate = match.group(1).rstrip(".,;:)")
            if "$" in candidate or candidate in SKIP_EXACT:
                continue
            if candidate.endswith("/"):
                continue
            yield source.name, candidate


class WorkflowReferenceTests(unittest.TestCase):
    def test_every_referenced_script_is_tracked(self):
        tracked = tracked_paths()
        missing = []
        untracked = []
        for source, candidate in referenced_paths():
            if not (ROOT / candidate).exists() and not any(
                path.startswith(candidate + "/") for path in tracked
            ):
                missing.append(f"{source}: {candidate}")
            elif candidate not in tracked:
                untracked.append(f"{source}: {candidate}")
        self.assertEqual([], missing, f"referenced but absent: {missing}")
        self.assertEqual(
            [],
            untracked,
            "referenced files exist locally but are not committed: " + "; ".join(untracked),
        )

    def test_the_check_covers_a_meaningful_number_of_references(self):
        count = len(list(referenced_paths()))
        self.assertGreater(count, 20, "the reference scan found suspiciously few paths")


if __name__ == "__main__":
    unittest.main()
