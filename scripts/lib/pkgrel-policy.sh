#!/usr/bin/env bash
# pkgrel 策略的单一实现。所有会改动 pkgrel 的入口（pkgrel-floor.sh、
# prepare-build-source.sh、auto-repair.sh 的 bump_pkgrel）与校验入口
# （verify-publish-inputs.sh、write-back-pkgrel.sh）都必须 source 本文件，
# 不得各自维护一份解析 / 比较 / 递增逻辑：四份实现已经漂移过两次
# （quirc 的 pkgrel 行尾注释让 ABI 重建在第一步报 unsupported；
# .PKGINFO 根本没有 pkgrel 字段让回写长期空转），见
# reports/pkgbuild-optimization/pkgrel-flow-audit.md §2.3。
#
# 仓库策略（pkgrel 形状）：
#   * 合法形状只有整数（5）与一段小数（2.6）；其余形状（三段、字母后缀）
#     属于「需要人工处理」，递增入口必须明确报错，不允许猜测。
#   * `.pkgrel-floor-skip` 是 repack 包（payload 为上游预构建产物，本仓库
#     不做编译链接）对一切 pkgrel 递增的显式退出。判据只有一个：文件存在。
#   * 比较 / 回写闸门的语义是「宁可漏拦，不能误拦」：出现判不了的分段时
#     方向交给 pacman 的 vercmp。
#
# 用法（调用方脚本内）：
#   script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=lib/pkgrel-policy.sh
#   source "${script_dir}/lib/pkgrel-policy.sh"

# .pkgrel-floor-skip：0 = 该包显式退出 pkgrel 递增。
pkgrel_policy_skip() { # <package-dir>
    [[ -f "$1/.pkgrel-floor-skip" ]]
}

# 读标量字段：行尾注释（quirc: `pkgrel=5  # emoeem overlay: ...`）与空白
# 一并去掉后打印；没有可解析的行时输出为空。
pkgrel_policy_field() { # <file> <key>
    awk -v key="$2" '
        index($0, key "=") == 1 {
            value = substr($0, length(key) + 2)
            sub(/#.*/, "", value)
            gsub(/[[:space:]]/, "", value)
            print value
            exit
        }' "$1"
}

pkgrel_policy_parse() { # <PKGBUILD-path>; 打印 pkgrel 标量
    pkgrel_policy_field "$1" pkgrel
}

pkgrel_policy_is_supported() { # <rel>; 0 = 整数或一段小数（仓库允许的形状）
    [[ "$1" =~ ^[0-9]+$ || "$1" =~ ^[0-9]+\.[0-9]+$ ]]
}

# 点分段按整数比较，不是浮点也不是字典序：2.10 比 2.9 新，2.11 比 2.6 新。
# 段数不足补 0（3 与 3.0 相等）。出现非数字段时返回 1（判不了），由调用方
# 决定是放行还是拒绝。
pkgrel_policy_cmp() { # <a> <b>; 输出 -1 / 0 / 1
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

# candidate 是否 <= baseline（0 = 是）。出现非数字段（判不了）时同样返回 0：
# 发布 / 回写闸门宁可漏拦也不能误拦一次正常前进。
pkgrel_policy_at_most() { # <candidate> <baseline>
    local comparison
    comparison="$(pkgrel_policy_cmp "$1" "$2")" || return 0
    [[ "$comparison" != 1 ]]
}

# 抬高一档并保持段数：5 → 6、2.6 → 2.7、2.11 → 2.12。
# 形状不支持（含三段与空值）时返回 1，调用方必须报错而不是猜。
pkgrel_policy_next() { # <rel>
    local rel="$1"
    pkgrel_policy_is_supported "$rel" || return 1
    if [[ "$rel" == *.* ]]; then
        printf '%s.%d' "${rel%.*}" "$(( 10#${rel#*.} + 1 ))"
    else
        printf '%d' "$(( 10#$rel + 1 ))"
    fi
}

# 把新 pkgrel 写进 PKGBUILD 并保持 .SRCINFO 同源。先在临时文件里生成两份新
# 内容、都成功后再落盘：PKGBUILD 已改而 .SRCINFO 写失败会让构建副本处于
# 「源码与元数据不一致」的半修改状态（build-in-arch.sh 的 .SRCINFO diff 会
# 拦住它，但那是一次本可避免的失败）。
#
# PKGBUILD 只替换 `pkgrel=` 后面的数字，行尾注释原样保留（quirc 的
# `pkgrel=6  # emoeem overlay: ...` 是本地定制的文档，test-pkgrel-floor 的
# 用例 12 把它钉住了）。调用方契约：必须先用 pkgrel_policy_parse +
# pkgrel_policy_is_supported 校验过当前值，否则数字模式不匹配时 PKGBUILD
# 不变而 .SRCINFO 被改，会制造出半修改状态。
#
# 两个文件都不存在 .SRCINFO 且 PATH 里没有 makepkg 时只改 PKGBUILD：AUR 同步
# 的 CI runner 就在这个形态下运行，它会在本函数之后自己用 makepkg 重新生成
# .SRCINFO，这里静默是契约的一部分，不是遗漏。
pkgrel_policy_apply() { # <package-dir> <new-rel>
    local package_dir="$1" new_rel="$2"
    local pkgbuild="$package_dir/PKGBUILD"
    local srcinfo="$package_dir/.SRCINFO"
    local tmp_pkg tmp_src gen_dir=""
    local have_srcinfo=false have_generated=false

    tmp_pkg="$(mktemp "$package_dir/.PKGBUILD.pkgrel-tmp.XXXXXX")" || return 1
    if ! sed -E "s/^pkgrel=[0-9]+(\.[0-9]+)*/pkgrel=${new_rel}/" "$pkgbuild" > "$tmp_pkg"; then
        rm -f "$tmp_pkg"
        return 1
    fi
    if [[ -f "$srcinfo" ]]; then
        have_srcinfo=true
        tmp_src="$(mktemp "$package_dir/.SRCINFO.pkgrel-tmp.XXXXXX")" || {
            rm -f "$tmp_pkg"
            return 1
        }
        if ! sed -E "s/^([[:space:]]*)pkgrel([[:space:]]*)=.*/\1pkgrel\2= ${new_rel}/" \
                "$srcinfo" > "$tmp_src"; then
            rm -f "$tmp_pkg" "$tmp_src"
            return 1
        fi
    elif command -v makepkg > /dev/null 2>&1; then
        # 目录里还没有 .SRCINFO（AUR 同步的 staged 副本、测试夹具）：由
        # makepkg 从**替换后的 PKGBUILD**生成，而不是磁盘上的旧文件，否则
        # .SRCINFO 会落后一档。makepkg 只认名为 PKGBUILD 的文件，所以把替换
        # 结果放进一次性子目录再跑；--printsrcinfo 只解析元数据，不需要源码
        # 在位，但 makepkg 坚持校验 BUILDIR/PKGDEST 可写（check-package.sh
        # 同款处理）。生成失败不落盘任何文件，避免半修改状态。
        gen_dir="$(mktemp -d "$package_dir/.pkgrel-gen.XXXXXX")" || {
            rm -f "$tmp_pkg"
            return 1
        }
        cp "$tmp_pkg" "$gen_dir/PKGBUILD" || {
            rm -rf "$gen_dir" "$tmp_pkg"
            return 1
        }
        if ! ( cd "$gen_dir" &&
                BUILDDIR="$gen_dir" SRCDEST="$gen_dir" \
                    PKGDEST="$gen_dir" LOGDEST="$gen_dir" \
                    makepkg --printsrcinfo > "$gen_dir/.SRCINFO" ); then
            rm -rf "$gen_dir" "$tmp_pkg"
            return 1
        fi
        have_generated=true
        tmp_src="$gen_dir/.SRCINFO"
    fi

    # 元数据先落盘、源码后落盘。两次 mv 之间是仅存的非原子缝隙；mv 在同一
    # 目录内失败只可能是目标盘满或权限被夺，而这两种情况下前面的 sed 早已
    # 失败退出，走不到这里。
    if [[ "$have_srcinfo" == true || "$have_generated" == true ]]; then
        mv -f "$tmp_src" "$srcinfo" || {
            rm -rf "$tmp_src" "$tmp_pkg" "$gen_dir"
            return 1
        }
    fi
    mv -f "$tmp_pkg" "$pkgbuild" || {
        rm -rf "$tmp_pkg" "$gen_dir"
        return 1
    }
    if [[ -n "$gen_dir" ]]; then
        rm -rf "$gen_dir"
    fi
}
