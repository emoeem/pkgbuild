#!/usr/bin/env bash
# 生成发布仓库的 ABI 清单：<pkg>\t<version>\t<ELF NEEDED...>，一行一个包。
# 有了这个 KB 级资产，漂移检测不必每轮下载整个仓库（几百 MB）就能判断
# 「已发布包需要的 SONAME 是否还存在」。在 archlinux 容器里运行（依赖
# bsdtar/readelf）。
#
# 用法：generate-abi-manifest.sh <repository-dir>
set -Eeuo pipefail
export LC_ALL=C

repository_dir="${1:?usage: generate-abi-manifest.sh <repository-dir>}"
repository_name="${REPOSITORY_NAME:-emoeem}"
[[ -d "$repository_dir" ]] || { printf 'not a directory: %s\n' "$repository_dir" >&2; exit 2; }

out="$repository_dir/${repository_name}-abi-manifest.txt"
stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT

{
    printf '# ABI manifest of the %s pacman repository (regenerated on every publish).\n' "$repository_name"
    printf '# pkg<TAB>version<TAB>space-separated ELF NEEDED entries\n'
    for package_file in "$repository_dir"/*.pkg.tar.zst; do
        [[ -e "$package_file" ]] || continue
        pkginfo="$(bsdtar -xOf "$package_file" .PKGINFO)"
        pkgname="$(printf '%s\n' "$pkginfo" | awk -F ' = ' '$1 == "pkgname" {print $2; exit}')"
        epoch="$(printf '%s\n' "$pkginfo" | awk -F ' = ' '$1 == "epoch" {print $2; exit}')"
        pkgver="$(printf '%s\n' "$pkginfo" | awk -F ' = ' '$1 == "pkgver" {print $2; exit}')"
        pkgrel="$(printf '%s\n' "$pkginfo" | awk -F ' = ' '$1 == "pkgrel" {print $2; exit}')"
        [[ -n "$pkgname" && -n "$pkgver" ]] || {
            printf 'skipping %s: incomplete .PKGINFO\n' "$(basename "$package_file")" >&2
            continue
        }
        version="$pkgver"
        [[ -n "$pkgrel" ]] && version="${pkgver}-${pkgrel}"
        if [[ -n "$epoch" && "$epoch" != "0" ]]; then
            version="${epoch}:${version}"
        fi

        rm -rf "${stage:?}/"*
        bsdtar -xf "$package_file" -C "$stage"
        needed="$(find "$stage" -type f -print0 |
            while IFS= read -r -d '' file; do
                magic=''
                LC_ALL=C IFS= read -r -N 4 magic < "$file" 2>/dev/null || true
                [[ "$magic" == $'\x7fELF' ]] || continue
                readelf -d "$file" 2>/dev/null |
                    awk '/NEEDED/ {gsub(/[\[\]]/, "", $NF); print $NF}'
            done | sort -u | paste -sd ' ' -)"
        printf '%s\t%s\t%s\n' "$pkgname" "$version" "$needed"
    done
} > "$out"

printf 'ABI manifest written: %s (%d packages)\n' \
    "$out" "$(grep -vc '^#' "$out")"
