#!/usr/bin/env python3
"""Run nvchecker using package-local source definitions and PKGBUILD baselines."""
from __future__ import annotations
import argparse, json, re, subprocess, sys, tomllib
from pathlib import Path


def pkgver_from_pkgbuild(path: Path) -> str:
    text = path.read_text(encoding='utf-8')
    match = re.search(r'(?m)^pkgver=(?:"([^"]+)"|\'([^\']+)\'|([^#\s]+))', text)
    if not match:
        raise ValueError(f'cannot find literal pkgver= in {path}')
    return next(group for group in match.groups() if group is not None)


def load_definitions(root: Path) -> tuple[dict[str, dict], dict[str, str]]:
    definitions: dict[str, dict] = {}
    baselines: dict[str, str] = {}
    for path in sorted((root / 'packages').glob('*/.nvchecker.toml')):
        data = tomllib.loads(path.read_text(encoding='utf-8'))
        entries = [(name, value) for name, value in data.items() if name != '__config__']
        if len(entries) != 1:
            raise ValueError(f'{path} must define exactly one nvchecker source')
        name, config = entries[0]
        pkgbuild = path.parent / 'PKGBUILD'
        current = pkgver_from_pkgbuild(pkgbuild)
        if config.get('source') == 'git' and config.get('use_commit'):
            match = re.search(r'\.g([0-9a-f]{7,})$', current)
            if not match:
                raise ValueError(f'git pkgver {current!r} does not contain a .g<sha> suffix')
            current = match.group(1)[:7]
        definitions[name] = config
        baselines[name] = current
    return definitions, baselines


def validate_new_versions(expected: set[str], versions: dict) -> None:
    missing = sorted(expected - set(versions))
    if missing:
        raise ValueError(
            'nvchecker returned no version for: ' + ', '.join(missing)
            + '; upstream lookup may have failed, refusing to report a clean scan'
        )


def parse_nvcmp_line(line: str) -> dict | None:
    """nvcmp 一行 -> update 记录;非比较行返回 None。

    箭头必须两种都收:nvcmp 用它的版本序决定 -> 还是 <-,而 git 提交源的
    版本是纯 hex sha,在该序下方向是任意的(vercmp 把数字段当整数比较,
    e0940ac 的 940 > e5a61be 的 5)——重建跟踪只关心「上游动了」。
    """
    match = re.match(r'(.+?)\s+(.+?)\s+(?:->|<-)\s+(.+)$', line.strip())
    if match:
        return {'package': match.group(1), 'current': match.group(2), 'upstream': match.group(3)}
    return None


def load_new_versions(path: Path) -> dict:
    """nvchecker ≥2.x(v2.22 实测)把 newver 写成 {"version": 2, "data": {name:
    {"version": ...}}} 的带版本外壳;旧版是扁平 {name: "version"}。归一成
    {name: version},否则顶层只剩 version/data 两个键,所有包都被判 missing
    (2026-10-11 upstream-check 首跑实测,workflow 建成后从未跑通过)。"""
    raw = json.loads(path.read_text(encoding='utf-8'))
    if isinstance(raw, dict) and isinstance(raw.get('data'), dict):
        flattened = {}
        for name, value in raw['data'].items():
            if isinstance(value, dict):
                value = value.get('version')
            flattened[name] = value
        return {name: version for name, version in flattened.items() if version is not None}
    return raw


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument('--root', type=Path, default=Path(__file__).resolve().parents[1])
    parser.add_argument('--config', type=Path, required=True)
    parser.add_argument('--oldver', type=Path, required=True)
    parser.add_argument('--newver', type=Path, required=True)
    parser.add_argument('--report', type=Path, required=True)
    parser.add_argument('--run', action='store_true', help='execute nvchecker and nvcmp')
    args = parser.parse_args()
    definitions, baselines = load_definitions(args.root)
    args.config.parent.mkdir(parents=True, exist_ok=True)
    config = {'__config__': {'oldver': str(args.oldver), 'newver': str(args.newver), 'max_concurrency': 4}}
    config.update(definitions)
    try:
        import tomli_w
        args.config.write_text(tomli_w.dumps(config), encoding='utf-8')
    except ImportError:
        # Minimal TOML writer for string/bool fields used by our package sources.
        def q(value: str) -> str: return json.dumps(value)
        lines = ['[__config__]', f'oldver = {q(str(args.oldver))}', f'newver = {q(str(args.newver))}', 'max_concurrency = 4', '']
        for name, entry in definitions.items():
            lines.append(f'[{q(name)}]')
            for key, value in entry.items():
                lines.append(f'{key} = {str(value).lower() if isinstance(value, bool) else q(value)}')
            lines.append('')
        args.config.write_text('\n'.join(lines), encoding='utf-8')
    args.oldver.write_text(json.dumps(baselines, indent=2, sort_keys=True) + '\n', encoding='utf-8')
    if args.run:
        # Never let a stale newver file make a failed upstream lookup look clean.
        args.newver.unlink(missing_ok=True)
        subprocess.run(['nvchecker', '-c', str(args.config)], check=True)
        new_versions = load_new_versions(args.newver)
        validate_new_versions(set(definitions), new_versions)
        result = subprocess.run(['nvcmp', '-c', str(args.config)], check=True, capture_output=True, text=True)
        updates = [update for line in result.stdout.splitlines() if (update := parse_nvcmp_line(line))]
        args.report.write_text(json.dumps({'updates': updates}, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'updates': updates}))
    else:
        args.report.write_text(json.dumps({'packages': sorted(definitions), 'baselines': baselines}, indent=2) + '\n', encoding='utf-8')
    return 0

if __name__ == '__main__':
    try: raise SystemExit(main())
    except (OSError, ValueError, tomllib.TOMLDecodeError) as exc:
        print(f'upstream version checker: {exc}', file=sys.stderr); raise SystemExit(2)
