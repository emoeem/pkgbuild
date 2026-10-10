#!/usr/bin/env bash
# 打印 packages/*/.rebuild-on 里声明的「仓库外触发」——这是一份逐包声明，替代了过去
# 只有一条全局白名单（scripts/data/external-sonames.txt）的做法：
#
#   * 全局白名单只要列了某个 soname，任何包缺这个库都会被掩盖；逐包声明之后，只有
#     真正声明过它的包才享受这条豁免，别的包缺同一个库仍然会被报成 STALE。
#   * 声明贴在包目录里，"为什么这个包需要重建" 不用再去翻一个中央文件。
#
# 用法：
#   list-rebuild-triggers.sh <packages-dir> [<package-dir-name>]
#
# 每行输出 `<kind>\t<package-dir>\t<arg1>[\t<arg2>]`：
#
#   soname	ffmpeg-full	libshine.so.3	shine
#   package	linuxqq-wayland-fix-git	linuxqq
#
# `soname` 由 scripts/check-repository-sonames.sh 消费（补充该包的 provider 集合，
# 并校验声明与产物一致）；`package` 由 scripts/check-dependency-drift.sh 消费
# （仓库解析不到版本的依赖走 AUR RPC）。格式本身由
# scripts/check-package-manifests.py 在 check.yml 里把关。
#
# 遇到不认识的行直接报错退出而不是跳过：静默跳过等于让检测范围悄悄变小。
set -Eeuo pipefail
export LC_ALL=C

packages_dir="${1:?usage: $0 <packages-dir> [<package-dir-name>]}"
only="${2:-}"
[[ -d "$packages_dir" ]] || { printf 'not a directory: %s\n' "$packages_dir" >&2; exit 2; }

shopt -s nullglob
files=()
if [[ -n "$only" ]]; then
    if [[ -f "${packages_dir}/${only}/.rebuild-on" ]]; then
        files=("${packages_dir}/${only}/.rebuild-on")
    fi
else
    files=("${packages_dir}"/*/.rebuild-on)
fi
shopt -u nullglob

for file in "${files[@]}"; do
    package="$(basename "$(dirname -- "$file")")"
    lineno=0
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        lineno=$((lineno + 1))
        line="${raw%%#*}"
        line="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$line")"
        [[ -n "$line" ]] || continue
        read -r -a fields <<<"$line"
        case "${fields[0]:-}" in
            soname)
                if (( ${#fields[@]} != 3 )); then
                    printf '%s:%d: expected `soname <soname> <provider>`\n' "$file" "$lineno" >&2
                    exit 1
                fi
                printf 'soname\t%s\t%s\t%s\n' "$package" "${fields[1]}" "${fields[2]}"
                ;;
            package)
                if (( ${#fields[@]} != 2 )); then
                    printf '%s:%d: expected `package <name>`\n' "$file" "$lineno" >&2
                    exit 1
                fi
                printf 'package\t%s\t%s\n' "$package" "${fields[1]}"
                ;;
            *)
                printf '%s:%d: unknown trigger kind `%s` (expected: soname, package)\n' \
                    "$file" "$lineno" "${fields[0]}" >&2
                exit 1
                ;;
        esac
    done < "$file"
done
