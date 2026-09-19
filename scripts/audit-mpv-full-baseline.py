#!/usr/bin/env python3
"""Audit mpv-emo against current AUR mpv-full and upstream Meson options."""
import argparse
import re
import sys
import urllib.request
from pathlib import Path

AUR_URL = "https://aur.archlinux.org/cgit/aur.git/plain/PKGBUILD?h=mpv-full"
UPSTREAM_URL = "https://raw.githubusercontent.com/mpv-player/mpv/v{ref}/meson.options"
PROVIDER_EQUIVALENTS = {"jack": {"jack", "pipewire-jack"}}
# Current upstream options intentionally outside the Linux mpv-full baseline.
# CI fails when a new upstream option appears outside this reviewed set.
KNOWN_UNREPRESENTED_UPSTREAM = {
    "disable-packet-pool", "dvda", "libcurl", "macos-bundle-category",
    "win32-smtc", "win32-subsystem",
}

def fetch(url):
    req = urllib.request.Request(url, headers={"User-Agent": "pkgbuild-mpv-full-audit/1.0"})
    with urllib.request.urlopen(req, timeout=20) as response:
        return response.read().decode()

def aur_pkgver(text):
    match = re.search(r"^pkgver=([^\n]+)", text, re.M)
    if not match:
        raise ValueError("Unable to determine mpv-full pkgver")
    return match.group(1).strip()

def parse_deps(text):
    match = re.search(r"^depends=\((.*?)\)", text, re.M | re.S)
    return set(re.findall(r"['\"]([^'\"]+)['\"]", match.group(1))) if match else set()

def parse_d_options(text):
    result = {}
    pattern = r"-D([A-Za-z0-9_-]+)=(?:'([^']*)'|\"([^\"]*)\"|([A-Za-z0-9_.+-]+))"
    for match in re.finditer(pattern, text):
        result[match.group(1)] = next(value for value in match.groups()[1:] if value is not None)
    return result

def parse_upstream_options(text):
    return set(re.findall(r"option\(\s*'([^']+)'", text))

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--package", default="packages/mpv-emo/PKGBUILD")
    parser.add_argument("--aur-pkgbuild")
    parser.add_argument("--upstream-options")
    args = parser.parse_args()

    local_text = Path(args.package).read_text()
    aur_text = Path(args.aur_pkgbuild).read_text() if args.aur_pkgbuild else fetch(AUR_URL)
    upstream_text = Path(args.upstream_options).read_text() if args.upstream_options else fetch(UPSTREAM_URL.format(ref=aur_pkgver(aur_text)))

    local_deps, aur_deps = parse_deps(local_text), parse_deps(aur_text)
    local_opts, aur_opts = parse_d_options(local_text), parse_d_options(aur_text)
    upstream_opts = parse_upstream_options(upstream_text)
    errors, warnings = [], []

    print("mpv-full baseline audit")
    print(f"  package: {args.package}")
    print(f"  upstream options: {len(upstream_opts)}")
    print()

    print("== Enabled AUR baseline features ==")
    for name, value in sorted(aur_opts.items()):
        if value not in {"enabled", "true"}:
            continue
        local = local_opts.get(name)
        ok = local in {"enabled", "true"}
        print(f"{'OK' if ok else 'MISSING':7} {name}: aur={value}, emo={local or '<implicit>'}")
        if not ok:
            errors.append(f"AUR enabled feature missing/disabled in mpv-emo: {name}")

    print()
    print("== AUR runtime dependency baseline ==")
    for dep in sorted(aur_deps):
        ok = bool(PROVIDER_EQUIVALENTS.get(dep, {dep}) & local_deps)
        print(f"{'OK' if ok else 'MISSING':7} {dep}")
        if not ok:
            errors.append(f"AUR runtime dependency missing in mpv-emo: {dep}")

    extras = sorted(local_deps - aur_deps)
    if extras:
        print()
        print("== mpv-emo extra runtime dependencies (allowed) ==")
        for dep in extras:
            print(f"EXTRA    {dep}")

    # An option is represented when either baseline explicitly mentions it, including an intentional disabled value such as mpv-fulls subrandr=disabled.
    unseen = sorted((upstream_opts - set(aur_opts) - set(local_opts)) - KNOWN_UNREPRESENTED_UPSTREAM)
    if unseen:
        print()
        print("== Upstream options not explicitly represented in either PKGBUILD ==")
        for name in unseen:
            print(f"NEW?     {name}")
        errors.append("Upstream option is not represented in mpv-full or mpv-emo; review the new feature: " + ", ".join(unseen))

    mismatches = [
        (name, aur_opts[name], local_opts[name])
        for name in sorted(set(aur_opts) & set(local_opts))
        if aur_opts[name] != local_opts[name]
    ]
    if mismatches:
        print()
        print("== Explicit option mismatches (review) ==")
        for name, aur, emo in mismatches:
            print(f"DIFF     {name}: aur={aur}, emo={emo}")

    print()
    print("RESULT:", "FAIL" if errors else "PASS")
    for error in errors:
        print("ERROR:", error, file=sys.stderr)
    for warning in warnings:
        print("WARNING:", warning, file=sys.stderr)
    return 1 if errors else 0

if __name__ == "__main__":
    raise SystemExit(main())
