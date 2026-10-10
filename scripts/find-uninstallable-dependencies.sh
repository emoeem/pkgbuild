#!/usr/bin/env bash
set -Eeuo pipefail

# 列出"仓库里有同名包、但依赖闭包装不上"的直接依赖。
#
# README 的依赖优先级把仓库源都满足不了的依赖交给 yay 从 AUR 构建安装。这条规则
# 必须对依赖的依赖同样成立：本仓库自己也可能收录了某个依赖的副本，而那个副本的
# 依赖只在 AUR 里（linuxqq-wayland-fix-git -> linuxqq）。pacman 这时不会回退到
# AUR，而是直接 "could not satisfy dependencies"，目标包连编译都不会开始
# （run 38023434807 的 linuxqq-clipsync-git）。
#
# 判据：依赖名能在仓库里找到（pacman -Si 成功），但 pacman 算不出它的可安装事务
# （pacman -Sp 失败）。只有这种情况才输出该依赖名，调用方据此改用 AUR 的副本；
# 纯 AUR 依赖由 yay 自己解析，因此原样跳过。
#
# usage: find-uninstallable-dependencies.sh <srcinfo-file>

export LC_ALL=C

srcinfo="${1:-}"
if [[ -z "$srcinfo" || ! -f "$srcinfo" ]]; then
    printf 'usage: %s <srcinfo-file>\n' "$(basename "$0")" >&2
    exit 2
fi

awk -F ' = ' '$1 ~ /^\t(depends|makedepends|checkdepends)$/ { print $2 }' "$srcinfo" |
    sed -E 's/[<>=].*$//' |
    sort -u |
    while IFS= read -r dependency; do
        [[ -n "$dependency" ]] || continue
        # 仓库里没有同名包：纯 AUR 依赖，yay 会自己从 AUR 解决。
        pacman -Si --noconfirm -- "$dependency" >/dev/null 2>&1 || continue
        # 仓库副本的依赖闭包完整时 pacman 能算出可安装事务。
        pacman -Sp --noconfirm -- "$dependency" >/dev/null 2>&1 && continue
        printf '%s\n' "$dependency"
    done
