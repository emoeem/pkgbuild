#!/usr/bin/env bash
# ABI 重建把 pkgrel bump 在构建副本（build-in-arch.sh 的 BUILD_ROOT 拷贝）里
# 完成，源码树仍保持旧值；不回写的话，下一次不带 bump 的普通重建会用旧
# pkgrel 构建出低版本包，而 create-repository.sh 按 pkgname 先删后拷，会把
# 发布版本静默倒回。这里以构建产物里的版本为准，把 PKGBUILD 与 .SRCINFO
# 拉齐后以 [skip ci] 提交回 main。
#
# 用法：write-back-pkgrel.sh <incoming-packages-dir> <repo-root>
set -Eeuo pipefail
export LC_ALL=C

incoming="${1:?usage: write-back-pkgrel.sh <incoming-packages-dir> <repo-root>}"
root="${2:?usage: write-back-pkgrel.sh <incoming-packages-dir> <repo-root>}"
[[ -d "$incoming" ]] || { printf 'missing incoming dir: %s\n' "$incoming" >&2; exit 2; }
[[ -d "$root/.git" ]] || { printf 'not a git repository: %s\n' "$root" >&2; exit 2; }

declare -A dir_of=()
for srcinfo in "$root"/packages/*/.SRCINFO; do
    [[ -f "$srcinfo" ]] || continue
    directory="$(basename "$(dirname "$srcinfo")")"
    dir_of["$directory"]="$directory"
    while IFS= read -r name; do
        [[ -n "$name" ]] && dir_of["$name"]="$directory"
    done < <(awk -F ' = ' '$1 == "pkgbase" || $1 == "pkgname" { print $2 }' "$srcinfo")
done

declare -A bumped_rel=()
shopt -s nullglob
for package_file in "$incoming"/*/*.pkg.tar.zst; do
    pkginfo="$(bsdtar -xOf "$package_file" .PKGINFO)"
    pkgbase="$(printf '%s\n' "$pkginfo" | awk -F ' = ' '$1 == "pkgbase" {print $2; exit}')"
    pkgname="$(printf '%s\n' "$pkginfo" | awk -F ' = ' '$1 == "pkgname" {print $2; exit}')"
    # .PKGINFO carries the whole `[epoch:]pkgver-pkgrel` in one pkgver field
    # (`pkgver = 9.0.2-2.6`): makepkg writes no pkgrel line at all. Reading a
    # pkgrel field that never exists left built_rel empty, and every package then
    # looked like "source pkgver already differs", so a bumped pkgrel was never
    # written back — ffmpeg-full, mpeghdec, vapoursynth-plugin-mlrt-ncnn-runtime
    # and xclip-git stayed a pkgrel behind the published repository forever.
    built_full="$(printf '%s\n' "$pkginfo" | awk -F ' = ' '$1 == "pkgver" {print $2; exit}')"
    if [[ "$built_full" == *-* ]]; then
        built_ver="${built_full%-*}"
        built_rel="${built_full##*-}"
    else
        built_ver="$built_full"
        built_rel=""
    fi
    if [[ -z "$built_rel" ]]; then
        printf 'SKIP %s: built version %s carries no pkgrel\n' \
            "${pkgbase:-$pkgname}" "$built_full" >&2
        continue
    fi

    directory="${dir_of[${pkgbase:-$pkgname}]:-}"
    if [[ -z "$directory" ]]; then
        printf 'SKIP %s: no matching source directory\n' "${pkgbase:-$pkgname}" >&2
        continue
    fi
    pkgbuild="$root/packages/$directory/PKGBUILD"
    srcinfo="$root/packages/$directory/.SRCINFO"

    # pkgver 也变了说明源码树已经走到更新的上游，pkgrel 以源码树为准；
    # 只有"同 pkgver、构建副本里 bump 过 pkgrel"才需要回写。
    src_ver="$(awk -F= '/^pkgver=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$pkgbuild")"
    src_rel="$(awk -F= '/^pkgrel=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$pkgbuild")"
    if [[ "$src_ver" != "$built_ver" ]]; then
        printf 'SKIP %s: source pkgver %s already differs from built %s\n' \
            "$directory" "$src_ver" "$built_ver" >&2
        continue
    fi
    if [[ "$src_rel" == "$built_rel" ]]; then
        continue
    fi
    sed -i -E "s/^pkgrel=.*/pkgrel=${built_rel}/" "$pkgbuild"
    sed -i -E "s/^(\tpkgrel = ).*/\1${built_rel}/" "$srcinfo"
    bumped_rel["$directory"]="$built_rel"
    printf 'WROTE BACK %s: pkgrel %s -> %s\n' "$directory" "$src_rel" "$built_rel"
done
shopt -u nullglob

if (( ${#bumped_rel[@]} == 0 )); then
    printf 'No pkgrel write-back needed.\n'
    exit 0
fi

git -C "$root" config user.name "github-actions[bot]"
git -C "$root" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
directories=()
for directory in "${!bumped_rel[@]}"; do
    git -C "$root" add "packages/$directory"
    directories+=("$directory")
done
if git -C "$root" diff --cached --quiet; then
    printf 'pkgrel write-back produced no diff.\n'
    exit 0
fi
git -C "$root" commit \
    -m "chore(build): write back bumped pkgrel for ${directories[*]} [skip ci]"
if [[ -n "${GH_TOKEN:-}" ]]; then
    # Keep checkout credentials disabled; grant this process only command-scoped
    # credentials for the required fast-forward pull and push.
    auth="$(printf 'x-access-token:%s' "$GH_TOKEN" | base64 -w0)"
    git -C "$root" -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth" pull --rebase origin main
    git -C "$root" -c "http.https://github.com/.extraheader=AUTHORIZATION: basic $auth" push origin HEAD
else
    # Preserve interactive/local use where the caller has configured git auth.
    git -C "$root" pull --rebase origin main
    git -C "$root" push origin HEAD
fi
