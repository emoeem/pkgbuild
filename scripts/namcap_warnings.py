#!/usr/bin/env python3
"""Normalize namcap warnings, apply exact-line exemptions, and derive issue key."""
import argparse
import hashlib
import json
import re
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--package', required=True)
    parser.add_argument('--warnings-file', required=True, type=Path)
    parser.add_argument('--ignore-file', type=Path)
    args = parser.parse_args()
    raw = args.warnings_file.read_text(encoding='utf-8', errors='replace').splitlines()
    warnings = sorted({re.sub(r'\s+', ' ', line.strip()) for line in raw if line.strip() and re.search(r'(^|\s)(w|warning|warn):', line, re.I)})
    ignored = set()
    if args.ignore_file and args.ignore_file.is_file():
        ignored = {re.sub(r'\s+', ' ', line.strip()) for line in args.ignore_file.read_text(encoding='utf-8').splitlines() if line.strip() and not line.lstrip().startswith('#')}
    active = [line for line in warnings if line not in ignored]
    normalized = '\n'.join(active)
    digest = hashlib.sha256(normalized.encode()).hexdigest()[:12] if active else ''
    print(json.dumps({'package': args.package, 'warnings': active, 'ignored': sorted(set(warnings) & ignored), 'key': f'[namcap] {args.package}: {digest}' if digest else '', 'warning_count': len(active)}, sort_keys=True))
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
