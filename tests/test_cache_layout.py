#!/usr/bin/env python3
"""Regression tests for the build cache layout and the builder generation.

Two properties keep the cache both effective and correct:

* caches are split per artefact class, so a new source tarball does not throw
  away the pacman packages and the compiler cache;
* every derived cache key contains the builder *generation*, which lives in a
  single file, so "the builder changed" is an explicit act instead of a side
  effect of editing the Dockerfile.
"""
import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BUILD = (ROOT / ".github/workflows/build.yml").read_text(encoding="utf-8") + "\n" + (ROOT / ".github/actions/setup-builder/action.yml").read_text(encoding="utf-8")
ACTION = (ROOT / ".github/actions/setup-builder/action.yml").read_text(encoding="utf-8")
BUILDER = (ROOT / ".github/workflows/builder.yml").read_text(encoding="utf-8")
DOCKERFILE = (ROOT / ".github/builder/Dockerfile").read_text(encoding="utf-8")
BUILD_IN_ARCH = (ROOT / "scripts/build-in-arch.sh").read_text(encoding="utf-8")

LAYERS = ("pacman", "sources", "cargo", "ccache")
GENERATION_EXPRESSION = "inputs.generation"
BUILDER_GENERATION_EXPRESSION = "steps.generation.outputs.value"


class BuilderGenerationTests(unittest.TestCase):
    def test_generation_file_is_a_single_well_formed_source_of_truth(self):
        path = ROOT / ".github/builder/generation"
        self.assertTrue(path.is_file(), "the builder generation file is missing")
        value = path.read_text(encoding="utf-8").strip()
        self.assertRegex(value, r"^[A-Za-z0-9._-]+$")

    def test_dockerfile_accepts_and_labels_the_generation(self):
        self.assertIn("ARG BUILDER_GENERATION", DOCKERFILE)
        self.assertIn("org.emoeem.builder.generation", DOCKERFILE)
        self.assertIn("ENV BUILDER_GENERATION", DOCKERFILE)

    def test_builder_workflow_passes_the_generation(self):
        self.assertIn(".github/builder/generation", BUILDER)
        self.assertIn("BUILDER_GENERATION=", BUILDER)
        self.assertIn(BUILDER_GENERATION_EXPRESSION, BUILDER)


class CacheLayerTests(unittest.TestCase):
    def cache_keys(self):
        return re.findall(r"^\s+key: (.+)$", BUILD, re.MULTILINE)

    def test_every_layer_has_its_own_key_containing_the_generation(self):
        keys = self.cache_keys()
        self.assertGreaterEqual(len(keys), 4)
        for layer in LAYERS:
            # Any key *version* is acceptable; what matters is that the layer
            # owns a key of its own and that the key tracks the generation.
            pattern = re.compile(rf"^{re.escape(layer)}-v\d+-")
            matching = [key for key in keys if pattern.match(key)]
            self.assertTrue(matching, f"no cache key for layer {layer}: {keys}")
            for key in matching:
                self.assertIn(
                    GENERATION_EXPRESSION,
                    key,
                    f"cache key for {layer} does not depend on the builder generation",
                )

    def test_source_cache_key_tracks_the_package_source_declaration(self):
        """A re-pinned checksum must change the source cache key.

        The cache key used to hash only the download helper, so updating a
        package's checksums restored a cache saved under an identical key.
        makepkg reports `-> Found <name>` for whatever the cache returned and
        hashes that, so the stale copy failed the validity check on every run
        and no rebuild could ever pass. The declaration has to be part of the
        key, and it has to be the *package's own* declaration.
        """
        sources_key = next(
            key for key in self.cache_keys() if re.match(r"^sources-v\d+-", key)
        )
        self.assertIn("packages/{0}/PKGBUILD", sources_key)
        self.assertIn("packages/{0}/.SRCINFO", sources_key)
        self.assertIn("inputs.package_name", sources_key)
        # The restore prefix must stay scoped to the same package, otherwise one
        # package's sources are restored into another package's cache entry.
        restore_entries = [
            line.strip()
            for line in ACTION.splitlines()
            if line.strip().startswith("sources-v")
        ]
        self.assertTrue(restore_entries, "no sources cache restore prefix found")
        self.assertIn("inputs.package_name", restore_entries[0])

    def test_layers_use_distinct_paths(self):
        for layer in LAYERS:
            self.assertIn(f"path: .cache/pkgbuild/{layer}", BUILD)

    def test_no_step_claims_the_whole_cache_tree(self):
        self.assertNotRegex(
            BUILD,
            r"^\s+path: \.cache/pkgbuild$",
            "a cache step still covers the whole .cache/pkgbuild tree",
        )

    def test_workflow_passes_the_generation_into_the_composite_cache_action(self):
        self.assertIn("generation: ${{ steps.generation.outputs.value }}", BUILD)

    def test_the_published_repository_is_never_cached(self):
        self.assertNotRegex(BUILD, r"^\s+path: .*cache/pkgbuild/repo")
        self.assertNotRegex(BUILD, r"--volume .*cache/pkgbuild/repo")

    def test_every_layer_can_restore_from_an_older_key(self):
        self.assertGreaterEqual(BUILD.count("restore-keys:"), 4)


class TimingIntegrationTests(unittest.TestCase):
    def test_ccache_statistics_are_scoped_to_a_single_build(self):
        self.assertIn("ccache --zero-stats", BUILD_IN_ARCH)
        self.assertIn("ccache -s", BUILD_IN_ARCH)

    def test_the_build_log_is_timestamped_and_measured(self):
        self.assertIn("build-timing.py", BUILD_IN_ARCH)
        self.assertIn("stamp", BUILD_IN_ARCH)
        self.assertIn("collect", BUILD_IN_ARCH)
        self.assertIn("timings.json", BUILD_IN_ARCH)

    def test_resource_facts_are_collected(self):
        self.assertIn("timing_resources", BUILD_IN_ARCH)
        self.assertIn("resources.txt", BUILD_IN_ARCH)


if __name__ == "__main__":
    unittest.main()
