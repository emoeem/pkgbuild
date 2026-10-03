#!/usr/bin/env bash
set -Eeuo pipefail

incoming="${1:-/incoming}"
root="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"

pkg_version_from_file() {
    bsdtar -xOf "$1" .PKGINFO |
        awk -F ' = ' '$1 == "pkgver" {print $2; exit}'
}

# BUMP_PKGREL 构建把 pkgrel 的 +1 做在构建副本里（prepare-build-source.sh），
# 产物比源码树正好高一档：整数 5→6、小数 2.6→2.7。发布校验必须放行这种
# 「有意的版本前进」，否则 ABI 重建永远过不了闸门；源码树的回写由发布
# 之后的 write-back 步骤（或提交的 pkgrel 更新）负责。
next_pkgrel() {
    local rel="$1"
    if [[ "$rel" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
        printf '%s.%d' "${BASH_REMATCH[1]}" "$((BASH_REMATCH[2] + 1))"
    elif [[ "$rel" =~ ^[0-9]+$ ]]; then
        printf '%d' "$((rel + 1))"
    fi
}

for pkg in "$incoming"/*/*.pkg.tar.zst "$incoming"/*.pkg.tar.zst; do
    [[ -f "$pkg" ]] || continue
    name="$(bsdtar -xOf "$pkg" .PKGINFO | awk -F ' = ' '$1 == "pkgname" {print $2; exit}')"
    actual="$(pkg_version_from_file "$pkg")"
    src="${root}/packages/${name}/.SRCINFO"
    [[ -f "$src" ]] || { printf 'Published package has no source metadata: %s\n' "$name" >&2; exit 1; }
    expected="$(awk -F ' = ' '$1 == "\tpkgver" {v=$2} $1 == "\tpkgrel" {r=$2} END {print v "-" r}' "$src")"
    if [[ "$actual" != "$expected" ]]; then
        # Git-based PKGBUILDs may derive pkgver() from fetched upstream sources.
        template_ver="$(awk -F= '/^pkgver=/{print $2; exit}' "${root}/packages/${name}/PKGBUILD")"
        pkgrel="$(awk -F= '/^pkgrel=/{print $2; exit}' "${root}/packages/${name}/PKGBUILD")"
        template_base="${template_ver%.r0.gunknown}"
        if grep -qE '^pkgver\(\)[[:space:]]*\{' "${root}/packages/${name}/PKGBUILD" \
            && [[ "$actual" =~ ^${template_base}\.r[0-9]+\.g[0-9a-f]+-${pkgrel}$ ]]; then
            printf 'Accepted resolved git pkgver for %s: %s (template=%s)\n' "$name" "$actual" "$expected"
            continue
        fi
        bumped_rel="$(next_pkgrel "$pkgrel")"
        if [[ -n "$bumped_rel" && "$actual" == "${expected%-*}-${bumped_rel}" ]]; then
            printf 'Accepted bumped pkgrel for %s: %s (source=%s)\n' "$name" "$actual" "$expected"
            continue
        fi
        printf 'Publication mismatch for %s: artifact=%s source=%s\n' "$name" "$actual" "$expected" >&2
        exit 1
    fi
done
