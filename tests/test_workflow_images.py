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

BUILDER_IMAGE = "ghcr.io/${{ github.repository_owner }}/pkgbuild-builder:latest"

# Workflows whose container-based detectors run unattended on cron.
SCHEDULED_DETECTORS = ("dependency-drift.yml", "maintenance.yml")


def workflow(name: str) -> str:
    return (WORKFLOWS / name).read_text(encoding="utf-8")


class DetectorImageTests(unittest.TestCase):
    def test_scheduled_detectors_use_the_ghcr_builder_image(self):
        for name in SCHEDULED_DETECTORS:
            text = workflow(name)
            self.assertIn(
                BUILDER_IMAGE,
                text,
                f"{name} does not define the GHCR builder image",
            )
            self.assertIn(
                '"$BUILDER_IMAGE"',
                text,
                f"{name} defines the builder image but does not run it",
            )

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
