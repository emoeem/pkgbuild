#!/usr/bin/env python3
import json
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts' / 'namcap_warnings.py'

class NamcapWarningTests(unittest.TestCase):
    def run_helper(self, warnings, ignore='', package='demo'):
        with tempfile.TemporaryDirectory() as td:
            warnings_file = Path(td) / 'warnings.txt'
            ignore_file = Path(td) / '.namcap-ignore'
            warnings_file.write_text(warnings, encoding='utf-8')
            ignore_file.write_text(ignore, encoding='utf-8')
            result = subprocess.run(['python3', str(SCRIPT), '--package', package, '--warnings-file', str(warnings_file), '--ignore-file', str(ignore_file)], check=True, capture_output=True, text=True)
            return json.loads(result.stdout)

    def test_issue_key_is_package_and_normalized_warning_content(self):
        first = self.run_helper('warning: dependency foo is not needed\nwarning: dependency foo is not needed\n')
        reordered = self.run_helper('warning:   dependency foo is not needed\n')
        changed = self.run_helper('warning: dependency bar is not needed\n')
        other_package = self.run_helper('warning: dependency foo is not needed\n', package='other')
        self.assertEqual(first['key'], reordered['key'])
        self.assertNotEqual(first['key'], changed['key'])
        self.assertNotEqual(first['key'], other_package['key'])
        self.assertEqual(first['warning_count'], 1)

    def test_exact_long_term_exemption(self):
        result = self.run_helper("warning: legacy soname is intentional\nwarning: missing dependency\n", "# reviewed\nwarning: legacy soname is intentional\n")
        self.assertEqual(result['warnings'], ['warning: missing dependency'])
        self.assertEqual(result['ignored'], ['warning: legacy soname is intentional'])

    def test_no_warnings_means_no_issue_key(self):
        result = self.run_helper('info: package looks fine\n')
        self.assertEqual(result['key'], '')
        self.assertEqual(result['warning_count'], 0)

if __name__ == '__main__':
    unittest.main()
