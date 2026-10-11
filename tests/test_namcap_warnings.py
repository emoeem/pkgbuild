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

    def test_bracket_list_order_does_not_change_key(self):
        # namcap 按 readdir 顺序输出方括号清单;同内容不同序必须同 key,
        # 否则去重失效、每次构建新建一个 issue。
        first = self.run_helper("demo W: Dependency glibc detected and implicitly satisfied (libraries ['usr/lib/libc.so.6', 'usr/lib/libm.so.6'] needed in files ['usr/bin/a', 'usr/bin/b'])\n")
        reordered = self.run_helper("demo W: Dependency glibc detected and implicitly satisfied (libraries ['usr/lib/libm.so.6', 'usr/lib/libc.so.6'] needed in files ['usr/bin/b', 'usr/bin/a'])\n")
        self.assertEqual(first['key'], reordered['key'])
        self.assertEqual(first['warnings'], reordered['warnings'])

    def test_ignore_line_matches_despite_list_order(self):
        # ignore 文件是历史时刻誊写的精确行,清单顺序必须不影响命中。
        result = self.run_helper(
            "demo W: Dependency glibc detected (libraries ['a.so', 'b.so'] needed in files ['x', 'y'])\n",
            "demo W: Dependency glibc detected (libraries ['b.so', 'a.so'] needed in files ['y', 'x'])\n",
        )
        self.assertEqual(result['warning_count'], 0)
        self.assertEqual(len(result['ignored']), 1)

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
