#!/usr/bin/env bash
set -Eeuo pipefail

incoming="${1:-/incoming}"
root="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

pkg_version_from_file() {
    bsdtar -xOf "$1" .PKGINFO |
        awk -F ' = ' '$1 == "pkgver" {print $2; exit}'
}

for pkg in "$incoming"/*/*.pkg.tar.zst "$incoming"/*.pkg.tar.zst; do
    [[ -f "$pkg" ]] || continue
    name="$(bsdtar -xOf "$pkg" .PKGINFO | awk -F ' = ' '$1 == "pkgname" {print $2; exit}')"
    actual="$(pkg_version_from_file "$pkg")"
    src="${root}/packages/${name}/.SRCINFO"
    [[ -f "$src" ]] || { printf 'Published package has no source metadata: %s\n' "$name" >&2; exit 1; }
    expected="$(awk -F ' = ' '$1 == "\tpkgver" {v=$2} $1 == "\tpkgrel" {r=$2} END {print v "-" r}' "$src")"
    [[ "$actual" == "$expected" ]] || {
        printf 'Publication mismatch for %s: artifact=%s source=%s\n' "$name" "$actual" "$expected" >&2
        exit 1
    }
done
