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

    def test_newver_schema_v2_envelope_is_unwrapped(self):
        # nvchecker ≥2.x 的带版本外壳:{"version": 2, "data": {name: {"version": ...}}}
        data = {'version': 2, 'data': {'quirc': {'version': '1.2'}, 'mpeghdec': {'version': '4.0.1', 'url': 'x'}}}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'newver.json'
            path.write_text(json.dumps(data), encoding='utf-8')
            self.assertEqual({'quirc': '1.2', 'mpeghdec': '4.0.1'}, _MODULE.load_new_versions(path))

    def test_newver_flat_schema_still_loads(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'newver.json'
            path.write_text(json.dumps({'quirc': '1.2'}), encoding='utf-8')
            self.assertEqual({'quirc': '1.2'}, _MODULE.load_new_versions(path))

    def test_nvcmp_line_parses_both_arrow_directions(self):
        # nvcmp 对 commit 源的箭头方向由 hex sha 的数字段决定,是任意的;
        # 两种箭头都必须进报告,否则 git 包的上游更新会被静默丢弃。
        forward = _MODULE.parse_nvcmp_line('demo v1.0 -> v1.1')
        self.assertEqual({'package': 'demo', 'current': 'v1.0', 'upstream': 'v1.1'}, forward)
        backward = _MODULE.parse_nvcmp_line('svt-jpeg-xs-git e0940ac <- e5a61be')
        self.assertEqual({'package': 'svt-jpeg-xs-git', 'current': 'e0940ac', 'upstream': 'e5a61be'}, backward)
        self.assertIsNone(_MODULE.parse_nvcmp_line('nothing to compare here'))

    def test_literal_pkgver_parser(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'PKGBUILD'
            path.write_text("pkgname=x\npkgver='1.2.3'\n", encoding='utf-8')
            self.assertEqual('1.2.3', pkgver_from_pkgbuild(path))

if __name__ == '__main__': unittest.main()
