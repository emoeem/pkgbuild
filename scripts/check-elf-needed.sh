#!/usr/bin/env bash
set -Eeuo pipefail

# 用法：
#   check-elf-needed.sh <root> <providers-file> [report-file]
#       列出 <root> 里 ELF 对象的 NEEDED 中，providers 表提供不了的条目（退出 1）。
#   check-elf-needed.sh --list-needed <root>
#       只列出 <root> 里所有 ELF 对象的 NEEDED 名字（去重），用于校验逐包声明的
#       .rebuild-on 是否仍然和产物一致（scripts/check-repository-sonames.sh）。
#   check-elf-needed.sh --require-needed <root> <declared-file>
#       反向校验：<declared-file> 每行一个 soname，必须真的出现在 <root> 的
#       NEEDED 里，否则打印那个名字并退出 1。声明是「豁免」，过期的豁免和缺库
#       一样有害，所以这里要求声明与产物一致。
#
# readelf translates the "Shared library:" label in a localized environment
# ("共享库：[libc.so.6]"), which turns every NEEDED entry into an unmatched
# name. Force the C locale so the parsing below always sees English.
export LC_ALL=C

mode=check
if [[ "${1:-}" == "--list-needed" ]]; then
    mode=list-needed
    shift
elif [[ "${1:-}" == "--require-needed" ]]; then
    mode=require-needed
    shift
fi

root="${1:?usage: check-elf-needed.sh <root> <providers-file> [report-file] | --list-needed <root>}"
providers_file="${2:-}"
report_file="${3:-}"
[[ -d "$root" ]] || exit 2

# 目录下所有 ELF 文件：用魔数判断，避免把脚本和文本喂给 readelf。
find_elf_files() {
    find "$1" -type f -print0 |
        while IFS= read -r -d '' f; do
            [[ "$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]] &&
                printf '%s\0' "$f"
        done
}

# 所有 ELF 对象的 NEEDED 名字，每个一行。
list_needed() {
    local elf
    while IFS= read -r -d '' elf; do
        readelf -d "$elf" 2>/dev/null |
            awk '/NEEDED/ {gsub(/[\[\]]/, "", $NF); print $NF}'
    done < <(find_elf_files "$1")
}

if [[ "$mode" == "list-needed" ]]; then
    list_needed "$root" | sort -u
    exit 0
fi

if [[ "$mode" == "require-needed" ]]; then
    declared_file="${2:?usage: check-elf-needed.sh --require-needed <root> <declared-file>}"
    [[ -f "$declared_file" ]] || exit 2
    needed_file="$(mktemp)"
    trap 'rm -f "$needed_file"' EXIT
    list_needed "$root" | sort -u > "$needed_file"
    absent=""
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        soname="${raw%%#*}"
        soname="$(sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$soname")"
        [[ -n "$soname" ]] || continue
        grep -qxF -- "$soname" "$needed_file" || absent+="${soname} "
    done < "$declared_file"
    absent="$(tr ' ' '\n' <<<"$absent" | sed '/^$/d' | sort -u | tr '\n' ' ')"
    if [[ -n "$absent" ]]; then
        printf '%s\n' "$absent"
        exit 1
    fi
    exit 0
fi

[[ -f "$providers_file" ]] || exit 2

# Load the providers once into an exact-match table. The previous
# `grep -qE "^${soname}(=|$)"` treated the SONAME as a regular expression, so
# names containing regex metacharacters (libstdc++.so.6, libatk-1.0.so.0, ...)
# never matched, and it re-read the file for every NEEDED entry.
declare -A provided=()
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  # Only shared-library names are ever queried below, so skipping everything
  # else keeps the table small when a caller passes a full file inventory
  # (291k names vs 7k library names measured on a real system).
  [[ "$line" == *.so* ]] || continue
  provided["$line"]=1
  # pacman SONAME provides spell a version differently than the linker:
  # libx264.so=165-64 -> libx264.so.165
  if [[ "$line" =~ ^(.*[.]so)=([0-9][0-9.]*)(-[0-9]+)?$ ]]; then
    provided["${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"]=1
  fi
done < "$providers_file"

missing=""
while IFS= read -r soname; do
  [[ "$soname" == *.so* ]] || continue
  if [[ -z "${provided[$soname]:-}" ]]; then
    missing+="${soname} "
  fi
done < <(list_needed "$root")

missing="$(tr ' ' '\n' <<<"$missing" | sed '/^$/d' | sort -u | tr '\n' ' ')"
[[ -z "$report_file" ]] || printf '%s\n' "$missing" > "$report_file"
if [[ -n "$missing" ]]; then
  printf '%s\n' "$missing"
  exit 1
fi
exit 0
