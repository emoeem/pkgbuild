#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
# Fixtures mirror what a publish actually stages: one directory per package base
# under the incoming tree, and the whole `[epoch:]pkgver-pkgrel` in the single
# .PKGINFO pkgver field, because makepkg writes no pkgrel line of its own and a
# flat fixture that faked one let a selector that read nothing pass CI while
# every real publish failed its install test.
mkdir -p "$work/incoming" "$work/old" "$work/new" "$work/other"
mkdir -p "$work/incoming/demo-old" "$work/incoming/demo-new" "$work/incoming/other"
printf 'pkgname = demo\npkgver = 1.9-1\narch = any\n' > "$work/old/.PKGINFO"
printf 'pkgname = demo\npkgver = 1.10-1\narch = any\n' > "$work/new/.PKGINFO"
printf 'pkgname = other\npkgver = 2.0-1\narch = any\n' > "$work/other/.PKGINFO"
tar -cf "$work/incoming/demo-old/demo-1.9-1-any.pkg.tar.zst" -C "$work/old" .PKGINFO
tar -cf "$work/incoming/demo-new/demo-1.10-1-any.pkg.tar.zst" -C "$work/new" .PKGINFO
tar -cf "$work/incoming/other/other-2.0-1-any.pkg.tar.zst" -C "$work/other" .PKGINFO
output="$(bash "$root/scripts/select-incoming-packages.sh" "$work/incoming")"
[[ "$(printf '%s\n' "$output" | wc -l)" == 2 ]]
[[ "$(printf '%s\n' "$output" | grep 'demo-1.10-1-any.pkg.tar.zst' | wc -l)" == 1 ]]
if [[ "$output" == *'demo-1.9-1-any.pkg.tar.zst'* ]]; then printf 'older duplicate package was selected.\n' >&2; exit 1; fi
printf 'Incoming package selection regression test passed.\n'
