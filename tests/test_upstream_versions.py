#!/usr/bin/env python3
import importlib.util
import json
import subprocess
import sys
import tempfile
import tomllib
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
_SPEC = importlib.util.spec_from_file_location('check_upstream_versions', ROOT / 'scripts/check-upstream-versions.py')
assert _SPEC is not None and _SPEC.loader is not None
_MODULE = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(_MODULE)
load_definitions = _MODULE.load_definitions
pkgver_from_pkgbuild = _MODULE.pkgver_from_pkgbuild
validate_new_versions = _MODULE.validate_new_versions

class UpstreamVersionTests(unittest.TestCase):
    def test_all_requested_packages_have_sources(self):
        definitions, baselines = load_definitions(ROOT)
        expected = {'quirc', 'mpeghdec', 'ffmpeg-full', 'svt-jpeg-xs-git', 'vapoursynth-plugin-mlrt-ncnn-runtime'}
        self.assertEqual(expected, set(definitions))
        self.assertEqual(expected, set(baselines))

    def test_git_pkgver_baseline_uses_short_commit_suffix(self):
        definitions, baselines = load_definitions(ROOT)
        self.assertEqual('e0940ac', baselines['svt-jpeg-xs-git'])
        self.assertEqual('git', definitions['svt-jpeg-xs-git']['source'])
        self.assertTrue(definitions['svt-jpeg-xs-git']['use_commit'])

    def test_release_sources_are_not_aur_sources(self):
        definitions, _ = load_definitions(ROOT)
        self.assertEqual('regex', definitions['ffmpeg-full']['source'])
        self.assertEqual('github', definitions['quirc']['source'])
        self.assertEqual('github', definitions['mpeghdec']['source'])

    def test_combined_config_writer_produces_valid_toml_and_baselines(self):
        with tempfile.TemporaryDirectory() as directory:
            tmp = Path(directory)
            report = tmp / 'report.json'
            subprocess.run([
                sys.executable, str(ROOT / 'scripts/check-upstream-versions.py'),
                '--root', str(ROOT), '--config', str(tmp / 'sources.toml'),
                '--oldver', str(tmp / 'oldver.json'), '--newver', str(tmp / 'newver.json'),
                '--report', str(report),
            ], check=True, capture_output=True, text=True)
            config = tomllib.loads((tmp / 'sources.toml').read_text(encoding='utf-8'))
            oldver = json.loads((tmp / 'oldver.json').read_text(encoding='utf-8'))
            expected = {'quirc', 'mpeghdec', 'ffmpeg-full', 'svt-jpeg-xs-git', 'vapoursynth-plugin-mlrt-ncnn-runtime'}
            self.assertIn('__config__', config)
            self.assertEqual(expected, set(oldver))
            self.assertEqual('e0940ac', oldver['svt-jpeg-xs-git'])

    def test_missing_upstream_results_fail_instead_of_looking_clean(self):
        with self.assertRaisesRegex(ValueError, 'refusing to report a clean scan'):
            validate_new_versions({'quirc', 'mpeghdec'}, {'quirc': '1.2.3'})

    def test_missing_upstream_results_are_not_treated_as_clean(self):
        with self.assertRaisesRegex(ValueError, 'no version for: quirc'):
            _MODULE.validate_new_versions({'quirc', 'mpeghdec'}, {'mpeghdec': '4.0.1'})

    def test_literal_pkgver_parser(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'PKGBUILD'
            path.write_text("pkgname=x\npkgver='1.2.3'\n", encoding='utf-8')
            self.assertEqual('1.2.3', pkgver_from_pkgbuild(path))

if __name__ == '__main__': unittest.main()
