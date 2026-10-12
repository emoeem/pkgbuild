#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/incoming" "$work/old" "$work/new" "$work/other"
printf 'pkgname = demo\npkgver = 1.9\npkgrel = 1\narch = any\n' > "$work/old/.PKGINFO"
printf 'pkgname = demo\npkgver = 1.10\npkgrel = 1\narch = any\n' > "$work/new/.PKGINFO"
printf 'pkgname = other\npkgver = 2.0\npkgrel = 1\narch = any\n' > "$work/other/.PKGINFO"
tar -cf "$work/incoming/demo-old.pkg.tar.zst" -C "$work/old" .PKGINFO
tar -cf "$work/incoming/demo-new.pkg.tar.zst" -C "$work/new" .PKGINFO
tar -cf "$work/incoming/other.pkg.tar.zst" -C "$work/other" .PKGINFO
output="$(bash "$root/scripts/select-incoming-packages.sh" "$work/incoming")"
[[ "$(printf '%s\n' "$output" | wc -l)" == 2 ]]
[[ "$(printf '%s\n' "$output" | grep 'demo-new.pkg.tar.zst' | wc -l)" == 1 ]]
if [[ "$output" == *'demo-old.pkg.tar.zst'* ]]; then printf 'older duplicate package was selected.\n' >&2; exit 1; fi
printf 'Incoming package selection regression test passed.\n'
