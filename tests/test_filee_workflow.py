#!/usr/bin/env python3
"""Invariants for the unattended Filee release updater.

Filee ships a prebuilt tarball, so an unattended bump is only the version and
checksum. These tests pin the parts that make that safe:

* no pull request and an explicit push credential;
* the metadata check and the candidate build run before the commit;
* every publish-side step is guarded by `changed == 'true'`;
* the rebuild is dispatched explicitly, because a GITHUB_TOKEN push does not
  trigger other workflows.
"""
from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/filee-update.yml"
GUARD = "if: steps.update.outputs.changed == 'true'"


def workflow_text() -> str:
    return WORKFLOW.read_text(encoding="utf-8")


def step_block(name: str) -> str:
    """Return one step's YAML block, from its `- name:` to the next step."""
    text = workflow_text()
    match = re.search(rf"^      - name: {re.escape(name)}\n", text, re.MULTILINE)
    assert match, f"workflow has no step named {name!r}"
    rest = text[match.end() :]
    following = re.search(r"^      - name: ", rest, re.MULTILINE)
    return rest[: following.start()] if following else rest


class UnattendedPublishTests(unittest.TestCase):
    def test_no_pull_request_is_opened(self):
        text = workflow_text()
        self.assertNotIn("gh pr create", text)
        self.assertNotIn("pull-requests: write", text)

    def test_bump_is_pushed_to_main_with_an_explicit_credential(self):
        block = step_block("Commit and push")
        self.assertIn("git commit -m", block)
        self.assertIn("http.https://github.com/.extraheader=AUTHORIZATION: basic", block)
        self.assertIn("persist-credentials: false", step_block("Checkout"))

    def test_gates_run_before_the_commit(self):
        text = workflow_text()
        metadata = text.index("scripts/check-package.sh filee-bin")
        build = text.index("- name: Build the candidate package")
        commit = text.index("- name: Commit and push")
        self.assertLess(metadata, commit, "the makepkg .SRCINFO check must precede the commit")
        self.assertLess(build, commit, "the candidate build must precede the commit")

    def test_metadata_gate_runs_makepkg_through_the_builder(self):
        block = step_block("Validate package metadata")
        self.assertIn("scripts/check-package.sh filee-bin", block)
        self.assertIn("--user builder", block)

    def test_candidate_build_still_verifies_the_built_package(self):
        block = step_block("Build the candidate package")
        self.assertIn("scripts/build-in-arch.sh", block)
        self.assertIn("sha256sum --check SHA256SUMS", block)
        self.assertIn("CLEAN_CHROOT_BUILD=0", block)
        self.assertIn("dist/filee-bin.runtime.json", block)

    def test_rebuild_is_dispatched_explicitly(self):
        block = step_block("Trigger rebuild")
        self.assertIn("gh workflow run build.yml", block)
        self.assertIn("-f packages=filee-bin", block)
        # The planner also selects repository-drift packages; an unrelated
        # failure must not strand a Filee bump that already built and passed
        # runtime verification.
        self.assertIn("-f allow_partial_publish=true", block)
        self.assertIn("actions: write", workflow_text())

    def test_every_publish_side_step_stays_guarded(self):
        for name in (
            "Read builder generation",
            "Set up CachyOS builder",
            "Validate package metadata",
            "Build the candidate package",
            "Commit and push",
            "Trigger rebuild",
        ):
            with self.subTest(step=name):
                self.assertIn(GUARD, step_block(name))

    def test_main_branch_updates_are_serialised(self):
        text = workflow_text()
        self.assertIn("group: main-branch-updates", text)
        self.assertIn("cancel-in-progress: false", text)

    def test_updater_runs_before_change_detection(self):
        text = workflow_text()
        self.assertLess(
            text.index("scripts/update-filee.py --apply"),
            text.index("echo 'changed=false'"),
        )


if __name__ == "__main__":
    unittest.main()
