#!/usr/bin/env bash
set -Eeuo pipefail

incoming="${1:-/incoming}"
root="${2:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
# 已发布仓库目录（x86_64 包所在目录）。给了它就会额外检查「这次发布是不是
# 真的能让已安装的机器升上去」；没给就不检查，保持脚本可单独使用。
published="${3:-}"

pkg_version_from_file() {
    bsdtar -xOf "$1" .PKGINFO |
        awk -F ' = ' '$1 == "pkgver" {print $2; exit}'
}

published_version() { # <pkgname>; 已发布版本（该包还没发布过时为空）
    local name="$1" candidate
    [[ -n "$published" ]] || return 0
    for candidate in "$published/$name"-*.pkg.tar.zst; do
        [[ -f "$candidate" ]] || continue
        pkg_version_from_file "$candidate"
        return 0
    done
}

# pkgrel 可以是小数形式（2.6、2.10），不能当浮点比较：逐段按整数比。出现
# 非数字段时返回 1（不判），把方向交给 pacman 的 vercmp 语义，宁可漏拦也不能
# 误拦一次正常的发布。
pkgrel_at_most() { # <incoming> <published>; 0 = incoming <= published
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
        (( 10#$x < 10#$y )) && return 0
        (( 10#$x > 10#$y )) && return 1
    done
    return 0
}

# base 是纯点分数字段时回答「candidate 是否严格大于 baseline」（vercmp 方向）：
# 逐段按整数比，段数不足补 0；相等不算前进。scx-scheds-git 那类上游跨 base
# 发布（源码树 1.1.3.r522，构建解析出 1.1.4.r5）用它判方向。
base_is_newer() { # <candidate> <baseline>; 0 = candidate > baseline
    local a="$1" b="$2" i max x y
    local -a av bv
    IFS='.' read -r -a av <<< "$a"
    IFS='.' read -r -a bv <<< "$b"
    max=${#av[@]}
    (( ${#bv[@]} > max )) && max=${#bv[@]}
    for ((i = 0; i < max; i++)); do
        x="${av[i]:-0}"
        y="${bv[i]:-0}"
        (( 10#$x < 10#$y )) && return 1
        (( 10#$x > 10#$y )) && return 0
    done
    return 1
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
    # 已发布版本与本次产物相同（同 pkgver、同 epoch、pkgrel 没前进）时，pacman
    # 看不到任何升级：内容变了也送不到已经装过这个版本的机器上，只会把仓库里的
    # 同名版本静默覆盖掉。两种情况要分开处理：
    #
    #   * 走「有意 pkgrel+1 豁免」的发布撞上已发布版本 —— ffmpeg-full 就是这么
    #     出事的：write-back 失效让源码树停在 2.6，每次 ABI 重建都算出并发布
    #     9.0.2-2.7，2026-10-11 那版（对 openapv 1.1.3.0 链接 liboapv.so.11）
    #     覆盖了 10-03 的旧 2.7，装了旧 2.7 的机器永远升不到修好 liboapv 的
    #     那一版。撞车说明 bump 没有真的前进，必须失败，先修源码树的版本。
    #   * 普通路径下的同版本重发 —— VCS 包在上游没动时重建出来的版本号本来就
    #     不会前进，那是正常空转；发布是全有全无，绝不能因此让整批发布失败。
    #     只对静态包响亮地 WARNING（多半是改了 PKGBUILD 忘了 bump pkgrel）。
    #
    # 方向判不准的情况（pkgver 不同、pkgrel 含非数字段）留给 pacman 的 vercmp。
    published_value="$(published_version "$name")"
    already_published=no
    behind_published=no
    if [[ -n "$published_value" ]]; then
        actual_epoch=0
        actual_rest="$actual"
        if [[ "$actual_rest" == *:* ]]; then
            actual_epoch="${actual_rest%%:*}"
            actual_rest="${actual_rest#*:}"
        fi
        published_epoch=0
        published_rest="$published_value"
        if [[ "$published_rest" == *:* ]]; then
            published_epoch="${published_rest%%:*}"
            published_rest="${published_rest#*:}"
        fi
        if [[ "$actual_epoch" == "$published_epoch" \
            && "${actual_rest%-*}" == "${published_rest%-*}" ]]; then
            if [[ "$actual_rest" == "$published_rest" ]]; then
                already_published=yes
            elif pkgrel_at_most "${actual_rest##*-}" "${published_rest##*-}"; then
                behind_published=yes
            fi
        fi
    fi
    expected="$(awk -F ' = ' '$1 == "\tpkgver" {v=$2} $1 == "\tpkgrel" {r=$2} END {print v "-" r}' "$src")"
    if [[ "$actual" != "$expected" ]]; then
        # Git-based PKGBUILDs may derive pkgver() from fetched upstream sources.
        template_ver="$(awk -F= '/^pkgver=/{v=$2; sub(/#.*/, "", v); gsub(/[[:space:]]/, "", v); print v; exit}' "${root}/packages/${name}/PKGBUILD")"
        # pkgrel 行可能带行尾注释（quirc: `pkgrel=5  # emoeem overlay: ...`），
        # 去掉空白和注释后才是版本号，否则 bumped-pkgrel 例外永远匹配不上。
        pkgrel="$(awk -F= '/^pkgrel=/{v=$2; sub(/#.*/, "", v); gsub(/[[:space:]]/, "", v); print v; exit}' "${root}/packages/${name}/PKGBUILD")"
        # .SRCINFO for a VCS package records the pkgver at the last metadata
        # refresh, while pkgver() resolves a newer commit during makepkg. Three
        # shapes exist: "<base>.rN.gHASH" (svt), a new base version after an
        # upstream release between two syncs (scx-scheds-git: 1.1.3.r522 in the
        # tree, 1.1.4.r5 in the artifact), and the bare "rN.<hash>" when
        # upstream has no conventional version number (linuxqq-wayland-fix-git).
        # Strip the cached suffix for the first two; the whole version is the
        # resolved part for the third.
        template_base="${template_ver%%.r[0-9]*.g*}"
        actual_ver="${actual%-*}"
        actual_rel="${actual##*-}"
        # makepkg resets pkgrel to 1 the moment pkgver() resolves a new version
        # (`==> Updated version: linuxqq-wayland-fix-git r119.c86286f-1` from a
        # source pkgrel of 2), so a deliberately bumped pkgrel on a VCS package
        # cannot survive a refreshed pkgver. The resolved pkgver is the forward
        # move here; the artifact pkgrel only has to be the source pkgrel or
        # makepkg's reset to 1.
        pkgrel_matches=no
        if [[ "$actual_rel" == "$pkgrel" || "$actual_rel" == 1 ]]; then
            pkgrel_matches=yes
        fi
        resolved_suffix=""
        if grep -qE '^pkgver\(\)[[:space:]]*\{' "${root}/packages/${name}/PKGBUILD" \
            && [[ "$pkgrel_matches" == yes ]]; then
            if [[ "$template_base" != "$template_ver" && "$actual_ver" == "$template_base".r* ]]; then
                suffix="${actual_ver#"$template_base".r}"
                if [[ "$suffix" =~ ^[0-9]+\.g[0-9a-f]+$ ]]; then
                    resolved_suffix="$suffix"
                fi
            elif [[ "$template_ver" =~ ^r[0-9]+\.[0-9a-f]+$ && "$actual_ver" =~ ^r[0-9]+\.[0-9a-f]+$ ]]; then
                resolved_suffix="${actual_ver#r}"
            else
                # 上游在两次同步之间发布了新的基础版本：树里是旧 base 的
                # .rN.gHASH，产物解析出新 base 的 .rN.gHASH。方向可判，要求
                # 严格前进——旧 base 的产物装到客户端升不上去，repo-add 还会
                # 把仓库副本静默倒回（ffmpeg-full 的教训）；base 相同或更旧
                # 都不属于这里，前者已由上面同 base 分支接住。
                actual_epoch=0
                actual_base=""
                if [[ "$actual_ver" =~ ^([0-9]+:)?([0-9]+(\.[0-9]+)*)\.r[0-9]+\.g[0-9a-f]+$ ]]; then
                    actual_epoch="${BASH_REMATCH[1]%:}"
                    actual_base="${BASH_REMATCH[2]}"
                fi
                template_num=""
                template_epoch=0
                if [[ "$template_base" =~ ^([0-9]+:)?([0-9]+(\.[0-9]+)*)$ ]]; then
                    template_epoch="${BASH_REMATCH[1]%:}"
                    template_num="${BASH_REMATCH[2]}"
                fi
                if [[ -n "$actual_base" && -n "$template_num" \
                    && "${actual_epoch:-0}" == "${template_epoch:-0}" ]] \
                    && base_is_newer "$actual_base" "$template_num"; then
                    resolved_suffix="new-base"
                fi
            fi
        fi
        if [[ -n "$resolved_suffix" ]]; then
            printf 'Accepted resolved git pkgver for %s: %s (template=%s)\n' "$name" "$actual" "$expected"
            continue
        fi
        bumped_rel="$(next_pkgrel "$pkgrel")"
        if [[ -n "$bumped_rel" && "$actual" == "${expected%-*}-${bumped_rel}" ]]; then
            # bump 之后的版本如果撞上（或落后于）已发布版本，这次 bump 根本
            # 没有前进：发布出去客户端也升不上去，只能先让源码树追上仓库。
            if [[ "$already_published" == yes || "$behind_published" == yes ]]; then
                printf 'Publication would not upgrade %s: artifact=%s already published=%s; the pkgrel bump lands on a version installed clients already have — reconcile the source pkgrel (write-back) instead of republishing it\n' \
                    "$name" "$actual" "$published_value" >&2
                exit 1
            fi
            printf 'Accepted bumped pkgrel for %s: %s (source=%s)\n' "$name" "$actual" "$expected"
            continue
        fi
        # 构建前的 pkgrel 对齐（pkgrel-floor.sh --against-repository）会把 pkgrel
        # 抬到已发布版本之上，产物因此比源码树的 .SRCINFO 更新 —— 这是有意的
        # 前进，不是版本错配。只放行同 pkgver、pkgrel 严格更大，且没有撞上/落后
        # 于已发布版本的情况（后两种上面和下面都会拒绝）。
        expected_ver="${expected%-*}"
        expected_rel="${expected##*-}"
        if [[ "$actual_ver" == "$expected_ver" \
            && "$already_published" == no && "$behind_published" == no ]] \
            && pkgrel_at_most "$expected_rel" "$actual_rel"; then
            printf 'Accepted repository-aligned pkgrel for %s: %s (source=%s)\n' \
                "$name" "$actual" "$expected"
            continue
        fi
        printf 'Publication mismatch for %s: artifact=%s source=%s\n' "$name" "$actual" "$expected" >&2
        exit 1
    fi
    # 普通路径下版本没有前进。对静态包来说「落后于已发布版本」是纯粹的倒退：
    # repo-add 不做版本比较，会把仓库里更高的同名版本覆盖掉，装了高版本的机器
    # 从此收不到任何更新（ffmpeg-full 9.0.2-2.11 → 2.6、mpeghdec 4.0.1-2 →
    # 4.0.1-1 都是这样发生的）。构建前的 pkgrel 对齐本该让这一步不可能出现，
    # 所以它一旦出现就是流水线坏了 —— 宁可让发布失败，也不再降一次仓库版本。
    if [[ "$behind_published" == yes ]] \
        && ! grep -qE '^pkgver\(\)[[:space:]]*\{' "${root}/packages/${name}/PKGBUILD"; then
        printf 'Publication would downgrade %s: artifact=%s is older than the published %s, and repo-add does not compare versions; rebuild with the pkgrel floor (pkgrel-floor.sh --against-repository) instead of publishing it\n' \
            "$name" "$actual" "$published_value" >&2
        exit 1
    fi
    # 同版本重发只响不拦：发布是全有全无，不能因为一个静态包没 bump pkgrel 就
    # 让整批（比如同批的另一个修复）发不出去。VCS 包重建后版本号不变是正常
    # 空转，连响都不必响。
    if [[ "$already_published" == yes ]] \
        && ! grep -qE '^pkgver\(\)[[:space:]]*\{' "${root}/packages/${name}/PKGBUILD"; then
        printf 'WARNING: %s %s is already published; this publish cannot upgrade anyone (bump pkgrel if the content changed)\n' \
            "$name" "$actual" >&2
    fi
done
