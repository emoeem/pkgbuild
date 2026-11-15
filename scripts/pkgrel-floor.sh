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

# pkgrel 的解析 / 比较 / 递增 / 写回统一走共享策略库；本脚本只保留两种对齐
# 模式（AUR 基线、已发布仓库下限）各自的判据。
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pkgrel-policy.sh
source "${script_dir}/lib/pkgrel-policy.sh"

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

# Repack 包（payload 是上游预构建产物，本仓库不做编译链接）可以放一个
# .pkgrel-floor-skip 显式退出抬档：payload 里没有任何一个字节由本仓库重链，
# 抬高 pkgrel 只会制造一次「上游没动、版本号自己变了」的发布，包内容与已发布
# 版本逐字节相同（dsh-desktop-linux 是当前的例子，其上游资产内嵌 -1 的
# pkgrel）。退出后同版本重建走发布闸门的 already_published WARNING，不静默。
# prepare-build-source.sh（ABI 重建入口）与 auto-repair.sh 识别同一个标记。
if pkgrel_policy_skip "$package_dir"; then
    printf 'pkgrel floor: %s opts out via .pkgrel-floor-skip; nothing to align.\n' "$package_name"
    exit 0
fi

pkgver="$(pkgrel_policy_field "$pkgbuild" pkgver)"
pkgrel="$(pkgrel_policy_field "$pkgbuild" pkgrel)"
epoch="$(pkgrel_policy_field "$pkgbuild" epoch)"
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
        reference_ver="$(pkgrel_policy_field "$reference" pkgver)"
        reference_rel="$(pkgrel_policy_field "$reference" pkgrel)"
        reference_epoch="$(pkgrel_policy_field "$reference" epoch)"
        if [[ -n "$reference_epoch" && "$reference_epoch" != 0 ]]; then
            exit 0
        fi
        # 上游换了 pkgver 就是一次真实的上游发布，pkgrel 从上游的基线重新开始，
        # 不保留本地的子版本号。
        [[ "$reference_ver" == "$pkgver" ]] || exit 0
        [[ -n "$reference_rel" ]] || exit 0
        comparison="$(pkgrel_policy_cmp "$pkgrel" "$reference_rel")" || exit 0
        [[ "$comparison" == -1 ]] || exit 0
        # 取高值，不是 +1：同步只是把上游的基线拿回来，本地已经走到 2.12 就
        # 停在 2.12；每同步一次涨一档会让版本号无意义地膨胀。
        pkgrel_policy_apply "$package_dir" "$reference_rel"
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
            comparison="$(pkgrel_policy_cmp "$pkgver" "$published_ver")" || comparison=""
            if [[ "$comparison" == -1 ]]; then
                printf 'pkgrel floor: repository publishes %s %s, which is newer than the source %s; refusing to build a downgrade\n' \
                    "$package_name" "$published_version" "$pkgver" >&2
                exit 1
            fi
            printf 'pkgrel floor: %s moves pkgver %s -> %s; version advances on its own.\n' \
                "$package_name" "$published_ver" "$pkgver"
            exit 0
        fi
        comparison="$(pkgrel_policy_cmp "$pkgrel" "$published_rel")" || {
            printf 'pkgrel floor: cannot compare pkgrel %s with published %s for %s; leaving it to vercmp.\n' \
                "$pkgrel" "$published_rel" "$package_name"
            exit 0
        }
        [[ "$comparison" == 1 ]] && {
            printf 'pkgrel floor: %s %s-%s is already newer than the published %s.\n' \
                "$package_name" "$pkgver" "$pkgrel" "$published_version"
            exit 0
        }
        new_rel="$(pkgrel_policy_next "$published_rel")" || {
            printf 'pkgrel floor: cannot raise pkgrel %s over the published %s for %s\n' \
                "$pkgrel" "$published_rel" "$package_name" >&2
            exit 1
        }
        pkgrel_policy_apply "$package_dir" "$new_rel"
        printf 'pkgrel floor: %s bumps pkgrel %s -> %s so the build is strictly newer than the published %s.\n' \
            "$package_name" "$pkgrel" "$new_rel" "$published_version"
        ;;
    *)
        usage
        ;;
esac
