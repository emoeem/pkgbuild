#!/usr/bin/env python3
"""Run nvchecker using package-local source definitions and PKGBUILD baselines."""
from __future__ import annotations
import argparse, io, json, re, subprocess, sys, tarfile, tomllib
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


def parse_db_members(fileobj) -> dict:
    """repo-add 数据库(解压后的 tar)-> {包名: 完整版本}。

    布局:<name>-<version>/desc,内含 %NAME%/%VERSION% 字段块。
    """
    versions: dict[str, str] = {}
    with tarfile.open(fileobj=fileobj, mode='r:') as tar:
        for member in tar:
            if not member.isfile() or not member.name.endswith('/desc'):
                continue
            fields: dict[str, list[str]] = {}
            key = None
            for line in tar.extractfile(member).read().decode(encoding='utf-8').splitlines():
                if line.startswith('%'):
                    key = line.strip('%')
                    fields[key] = []
                elif key and line:
                    fields[key].append(line)
            name = (fields.get('NAME') or [''])[0]
            version = (fields.get('VERSION') or [''])[0]
            if name and version:
                versions[name] = version
    return versions


def read_published_versions(db_path: Path) -> dict:
    zstd = subprocess.run(['zstd', '-dc', '--', str(db_path)], check=True, capture_output=True).stdout
    return parse_db_members(io.BytesIO(zstd))


def published_baseline(version: str, definition: dict) -> str:
    """把发布的完整版本归一成可与上游比较的基线。

    剥 epoch 与 pkgrel(pkgver 按 Arch 规则不含 '-');git 提交源与
    load_definitions 同款取 .g<sha> 短哈希。
    """
    text = re.sub(r'^\d+:', '', version)
    text = text.rsplit('-', 1)[0]
    if definition.get('source') == 'git' and definition.get('use_commit'):
        match = re.search(r'\.g([0-9a-f]{7,})$', text)
        if match:
            return match.group(1)[:7]
    return text


def resolve_baselines(definitions: dict, pkgbuild_baselines: dict, published: dict | None) -> tuple[dict, dict]:
    """基线优先取「已发布的版本」,PKGBUILD 只作未发布包的回退。

    -git 包的 pkgver 不回写进仓库,PKGBUILD 基线必然落后于已发布产物;
    与上游比对的正确问题是「发布的东西旧不旧」,所以基线应以发布仓库为准
    (2026-10-11 实测 svt 已发布 r123.ge5a61be 却按 PKGBUILD 的 r5.ge0940ac
    误报更新)。
    """
    baselines = dict(pkgbuild_baselines)
    origin = {name: 'pkgbuild' for name in baselines}
    if published:
        for name in baselines:
            if name in published:
                baselines[name] = published_baseline(published[name], definitions[name])
                origin[name] = 'published'
    return baselines, origin


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
    parser.add_argument('--published-db', type=Path,
                        help='published repository db; its versions override PKGBUILD baselines when given')
    parser.add_argument('--run', action='store_true', help='execute nvchecker and nvcmp')
    args = parser.parse_args()
    definitions, baselines = load_definitions(args.root)
    published = read_published_versions(args.published_db) if args.published_db else None
    baselines, baseline_origin = resolve_baselines(definitions, baselines, published)
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
        args.report.write_text(json.dumps({'updates': updates, 'baselines': baselines, 'baseline_origin': baseline_origin}, indent=2) + '\n', encoding='utf-8')
        print(json.dumps({'updates': updates, 'baseline_origin': baseline_origin}))
    else:
        args.report.write_text(json.dumps({'packages': sorted(definitions), 'baselines': baselines, 'baseline_origin': baseline_origin}, indent=2) + '\n', encoding='utf-8')
    return 0

if __name__ == '__main__':
    try: raise SystemExit(main())
    except (OSError, ValueError, tomllib.TOMLDecodeError) as exc:
        print(f'upstream version checker: {exc}', file=sys.stderr); raise SystemExit(2)
