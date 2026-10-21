#!/usr/bin/env bash
# 仓库里的版本号只允许前进。
#
# pacman 只按版本号判断「要不要升级」，所以仓库里发布一个不比已装版本新的包
# 等于什么都没发。更糟的是 repo-add 不做版本比较：它按 pkgname 覆盖，会把仓库
# 里更高的同名版本静默倒回低版本。ffmpeg-full（9.0.2-2.11 → 2.6）和 mpeghdec
# （4.0.1-2 → 4.0.1-1）就是这样让装了新版本的机器永远收不到后续更新的。
#
# 倒退的两个入口都收敛到这里，用同一条规则「抬到参照版本之上」：
#
#   --against-pkgbuild <PKGBUILD>
#       AUR 同步：上游 PKGBUILD 的 pkgrel 是基线，本地通过 .N 子版本号记录
#       自己的重建次数。同 pkgver 时不得把本地已经抬高的 pkgrel 拉回去。
#
#   --against-repository <repo-dir>
#       构建前：仓库里已发布的版本是下限，构建产物必须严格新于它，否则这次
#       构建发出去对已装客户端不是升级。
#
# 两种模式都跳过 VCS 包（版本在 makepkg 里由 pkgver() 解析，构建前不可知；
# 发布闸门 verify-publish-inputs.sh 用产物版本兜住）和带 epoch 的包（文件名
# 里没有 epoch，方向交给 pacman 的 vercmp）。
#
# 用法：
#   pkgrel-floor.sh packages/foo --against-pkgbuild /tmp/aur/foo/PKGBUILD
#   LOCAL_REPO_DIR=/localrepo pkgrel-floor.sh packages/foo --against-repository /localrepo
set -Eeuo pipefail

usage() {
    printf 'usage: %s <package-dir> --against-pkgbuild <PKGBUILD> | --against-repository <repo-dir>\n' "$0" >&2
    exit 2
}

(( $# == 3 )) || usage
package_dir="${1%/}"
mode="$2"
reference="${3%/}"

pkgbuild="$package_dir/PKGBUILD"
[[ -f "$pkgbuild" ]] || { printf 'pkgrel floor: no PKGBUILD in %s\n' "$package_dir" >&2; exit 2; }
package_name="$(basename "$package_dir")"

field() { # <file> <key>; 行尾注释与空白一并去掉（quirc: `pkgrel=5  # comment`）
    awk -v key="$2" '
        index($0, key "=") == 1 {
            value = substr($0, length(key) + 2)
            sub(/#.*/, "", value)
            gsub(/[[:space:]]/, "", value)
            print value
            exit
        }' "$1"
}

# 点分段按整数比较，不是浮点也不是字典序：2.10 比 2.9 新，2.11 比 2.6 新。
# 出现非数字段时返回 1（判不了），由调用方决定是放行还是拒绝。
dotted_cmp() { # <a> <b>; 输出 -1 / 0 / 1
    local a="$1" b="$2" i max x y
    local -a av bv
    IFS='.' read -r -a av <<< "$a"
    IFS='.' read -r -a bv <<< "$b"
    max=${#av[@]}
    (( ${#bv[@]} > max )) && max=${#bv[@]}
    for ((i = 0; i < max; i++)); do
        x="${av[i]:-0}"
        y="${bv[i]:-0}"
        [[ "$x" =~ ^[0-9]+$ && "$y" =~ ^[0-9]+$ ]] || return 1
        if (( 10#$x > 10#$y )); then printf '%s\n' 1; return 0; fi
        if (( 10#$x < 10#$y )); then printf '%s\n' -1; return 0; fi
    done
    printf '%s\n' 0
}

# 抬高一档并保持段数：2.11 → 2.12、3 → 4。
next_pkgrel() { # <rel>
    local rel="$1" head="" last
    if [[ "$rel" == *.* ]]; then
        head="${rel%.*}."
        last="${rel##*.}"
    else
        last="$rel"
    fi
    [[ "$last" =~ ^[0-9]+$ ]] || return 1
    printf '%s%d' "$head" "$((10#$last + 1))"
}

apply_pkgrel() { # <new-rel>
    local new_rel="$1"
    sed -i -E "s/^pkgrel=[0-9]+(\.[0-9]+)*/pkgrel=${new_rel}/" "$pkgbuild"
    # .SRCINFO 与 PKGBUILD 必须同源：构建流程后面会 diff 两者，只改一个会在
    # makepkg 之前就报 "SRCINFO mismatch"。pkgrel 只是一个标量字段（split
    # package 的 .SRCINFO 也只在 pkgbase 段写一次），按行替换与 makepkg
    # --printsrcinfo 的结果等价，而且不依赖 makepkg 是否在 PATH 里（测试与
    # 没有 pacman 的同步 runner 都能跑）。
    if [[ -f "$package_dir/.SRCINFO" ]]; then
        sed -i -E "s/^([[:space:]]*)pkgrel([[:space:]]*)=.*/\1pkgrel\2= ${new_rel}/" "$package_dir/.SRCINFO"
    elif command -v makepkg > /dev/null 2>&1; then
        ( cd "$package_dir" && makepkg --printsrcinfo > .SRCINFO )
    fi
}

pkgver="$(field "$pkgbuild" pkgver)"
pkgrel="$(field "$pkgbuild" pkgrel)"
epoch="$(field "$pkgbuild" epoch)"
[[ -n "$pkgver" && -n "$pkgrel" ]] || {
    printf 'pkgrel floor: %s has no parseable pkgver/pkgrel\n' "$package_name" >&2
    exit 2
}

if [[ -n "$epoch" && "$epoch" != 0 ]]; then
    printf 'pkgrel floor: %s uses epoch %s; leaving the version to vercmp.\n' \
        "$package_name" "$epoch"
    exit 0
fi
if grep -qE '^pkgver\(\)[[:space:]]*\{' "$pkgbuild"; then
    printf 'pkgrel floor: %s resolves pkgver() during makepkg; nothing to align here.\n' \
        "$package_name"
    exit 0
fi

case "$mode" in
    --against-pkgbuild)
        [[ -f "$reference" ]] || { printf 'pkgrel floor: no reference PKGBUILD %s\n' "$reference" >&2; exit 2; }
        reference_ver="$(field "$reference" pkgver)"
        reference_rel="$(field "$reference" pkgrel)"
        reference_epoch="$(field "$reference" epoch)"
        if [[ -n "$reference_epoch" && "$reference_epoch" != 0 ]]; then
            exit 0
        fi
        # 上游换了 pkgver 就是一次真实的上游发布，pkgrel 从上游的基线重新开始，
        # 不保留本地的子版本号。
        [[ "$reference_ver" == "$pkgver" ]] || exit 0
        [[ -n "$reference_rel" ]] || exit 0
        comparison="$(dotted_cmp "$pkgrel" "$reference_rel")" || exit 0
        [[ "$comparison" == -1 ]] || exit 0
        # 取高值，不是 +1：同步只是把上游的基线拿回来，本地已经走到 2.12 就
        # 停在 2.12；每同步一次涨一档会让版本号无意义地膨胀。
        apply_pkgrel "$reference_rel"
        printf 'pkgrel floor: %s keeps pkgrel %s instead of the upstream %s.\n' \
            "$package_name" "$reference_rel" "$pkgrel"
        ;;
    --against-repository)
        [[ -d "$reference" ]] || {
            printf 'pkgrel floor: no repository directory %s\n' "$reference" >&2
            exit 2
        }
        published_version=""
        shopt -s nullglob
        for artifact in "$reference/${package_name}-"*.pkg.tar.zst; do
            filename="${artifact##*/}"
            rest="${filename#"${package_name}-"}"
            [[ "$rest" == *-*.pkg.tar.zst ]] || continue
            candidate="${rest%-*.pkg.tar.zst}"
            [[ -n "$candidate" ]] && published_version="$candidate"
            break
        done
        shopt -u nullglob
        if [[ -z "$published_version" ]]; then
            printf 'pkgrel floor: %s is not published yet; nothing to align.\n' "$package_name"
            exit 0
        fi
        published_ver="${published_version%-*}"
        published_rel="${published_version##*-}"
        if [[ "$published_ver" != "$pkgver" ]]; then
            comparison="$(dotted_cmp "$pkgver" "$published_ver")" || comparison=""
            if [[ "$comparison" == -1 ]]; then
                printf 'pkgrel floor: repository publishes %s %s, which is newer than the source %s; refusing to build a downgrade\n' \
                    "$package_name" "$published_version" "$pkgver" >&2
                exit 1
            fi
            printf 'pkgrel floor: %s moves pkgver %s -> %s; version advances on its own.\n' \
                "$package_name" "$published_ver" "$pkgver"
            exit 0
        fi
        comparison="$(dotted_cmp "$pkgrel" "$published_rel")" || {
            printf 'pkgrel floor: cannot compare pkgrel %s with published %s for %s; leaving it to vercmp.\n' \
                "$pkgrel" "$published_rel" "$package_name"
            exit 0
        }
        [[ "$comparison" == 1 ]] && {
            printf 'pkgrel floor: %s %s-%s is already newer than the published %s.\n' \
                "$package_name" "$pkgver" "$pkgrel" "$published_version"
            exit 0
        }
        new_rel="$(next_pkgrel "$published_rel")" || {
            printf 'pkgrel floor: cannot raise pkgrel %s over the published %s for %s\n' \
                "$pkgrel" "$published_rel" "$package_name" >&2
            exit 1
        }
        apply_pkgrel "$new_rel"
        printf 'pkgrel floor: %s bumps pkgrel %s -> %s so the build is strictly newer than the published %s.\n' \
            "$package_name" "$pkgrel" "$new_rel" "$published_version"
        ;;
    *)
        usage
        ;;
esac
