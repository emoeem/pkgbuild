#!/usr/bin/env python3
"""Normalize namcap warnings, apply exact-line exemptions, and derive issue key."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def canonical(line: str) -> str:
    """把行内每个「引号条目列表」的条目排序,使 key 只由内容决定。

    namcap 的方括号清单(needed-in-files 等)按 readdir 顺序输出,每次构建
    都不同;只对行排序救不了行内顺序,同一组警告会算出不同 key,issue 去重
    因此失效(2026-10-11 实测 scx-scheds-git 堆了 27 个重复 issue)。ignore
    文件走同一个函数,已有的精确行豁免在归一化收紧后继续命中。
    """
    def sort_items(m: 're.Match[str]') -> str:
        items = re.findall(r"'([^']*)'", m.group(0))
        if not items:
            return m.group(0)
        return '[' + ', '.join(f"'{item}'" for item in sorted(items)) + ']'
    return re.sub(r'\[[^\]]*\]', sort_items, line)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--package', required=True)
    parser.add_argument('--warnings-file', required=True, type=Path)
    parser.add_argument('--ignore-file', type=Path)
    args = parser.parse_args()
    raw = args.warnings_file.read_text(encoding='utf-8', errors='replace').splitlines()
    warnings = sorted({canonical(re.sub(r'\s+', ' ', line.strip())) for line in raw if line.strip() and re.search(r'(^|\s)(w|warning|warn):', line, re.I)})
    ignored = set()
    if args.ignore_file and args.ignore_file.is_file():
        ignored = {canonical(re.sub(r'\s+', ' ', line.strip())) for line in args.ignore_file.read_text(encoding='utf-8').splitlines() if line.strip() and not line.lstrip().startswith('#')}
    active = [line for line in warnings if line not in ignored]
    normalized = '\n'.join(active)
    digest = hashlib.sha256(normalized.encode()).hexdigest()[:12] if active else ''
    print(json.dumps({'package': args.package, 'warnings': active, 'ignored': sorted(set(warnings) & ignored), 'key': f'[namcap] {args.package}: {digest}' if digest else '', 'warning_count': len(active)}, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
