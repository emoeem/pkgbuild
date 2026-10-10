#!/usr/bin/env bash
set -Eeuo pipefail

# 打印"仓库源装不上、必须改用 AUR 构建"的依赖名。
#
# README 的依赖优先级把仓库源都满足不了的依赖交给 yay 从 AUR 构建安装。这条规则
# 必须对依赖的依赖同样成立：本仓库自己也可能收录了某个依赖的副本，而那个副本的
# 依赖只在 AUR 里（linuxqq-wayland-fix-git -> linuxqq）。pacman 这时不会回退到
# AUR，而是直接 "could not satisfy dependencies"，目标包连编译都不会开始
# （run 38023434807 就是这种情形；触发它的那个桩包此后已退役，但规则本身对任何
# 此类依赖仍然成立）。
#
# 做法：对目标自己声明的每个依赖先做两次探测——
#   * pacman -Si 找不到同名包 → 纯 AUR 依赖，yay 自己会从 AUR 解决，跳过；
#   * pacman -Sp 算得出可安装事务 → 仓库里那份可用，跳过；
# 只有"仓库里有同名包、但依赖闭包装不上"的依赖才走到最后一步：从 pacman 的
# 事务报错里读出真正缺的那个名字，交给调用方用 yay 从 AUR 安装。装好之后依赖
# 闭包就完整了，仓库里的副本可以照常安装。
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
        # 闭包不完整：把 pacman 报出的、仓库源无论如何都提供不了的那个名字取出来。
        pacman -Sp --noconfirm -- "$dependency" 2>&1 |
            sed -nE \
                -e "s/.*unable to satisfy dependency '([^']*)'.*/\1/p" \
                -e "s/.*cannot resolve \"([^\"]*)\".*/\1/p" ||
            true
    done |
    sed -E 's/[<>=].*$//' |
    sort -u
