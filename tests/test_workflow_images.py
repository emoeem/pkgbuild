#!/usr/bin/env python3
"""Scheduled detector containers must not depend on anonymous Docker Hub pulls.

Docker Hub rate-limits unauthenticated pulls per source IP, and hosted runners
share pool addresses, so `docker run docker.io/cachyos/cachyos-v3:latest` can
fail with `toomanyrequests` (exit 125) at any time. Maintenance run 37989749507
lost its daily soname scan that way: the detector was fine, the pull was not.

Both unattended detectors therefore run the image the package builds use, which
this repository publishes to GHCR, where an anonymous pull needs no credentials
and is not rate limited. A failed pull must stay a loud failure, so the fix is
about *which* image is used, never about retrying the pull.
"""
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

BUILDER_SETUP = "uses: ./.github/actions/setup-builder"
BUILDER_OUTPUT = '"${{ steps.builder.outputs.image }}"'

# Workflows whose container-based detectors run unattended on cron.
SCHEDULED_DETECTORS = ("dependency-drift.yml", "maintenance.yml")


def workflow(name: str) -> str:
    return (WORKFLOWS / name).read_text(encoding="utf-8")


class DetectorImageTests(unittest.TestCase):
    def test_scheduled_detectors_use_the_ghcr_builder_image(self):
        for name in SCHEDULED_DETECTORS:
            text = workflow(name)
            self.assertIn(BUILDER_SETUP, text, f"{name} does not use the shared builder setup action")
            self.assertIn(BUILDER_OUTPUT, text, f"{name} does not run the resolved builder image")

    def test_build_and_publish_workflow_uses_cachyos_builder_for_repo_validation(self):
        text = workflow("build.yml")
        self.assertNotIn("docker.io/library/archlinux:base-devel", text)
        self.assertIn('"$BUILDER_IMAGE"', text)
        self.assertNotIn('docker.io/cachyos/cachyos-v3:latest', text)

    def test_scheduled_detectors_never_pull_from_docker_hub(self):
        for name in SCHEDULED_DETECTORS:
            offenders = [
                line.strip()
                for line in workflow(name).splitlines()
                if "docker.io/" in line and not line.lstrip().startswith("#")
            ]
            self.assertEqual(
                [],
                offenders,
                f"{name} must not pull from rate-limited Docker Hub: {offenders}",
            )


if __name__ == "__main__":
    unittest.main()
