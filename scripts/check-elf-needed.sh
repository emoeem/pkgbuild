#!/usr/bin/env bash
set -Eeuo pipefail

# readelf translates the "Shared library:" label in a localized environment
# ("共享库：[libc.so.6]"), which turns every NEEDED entry into an unmatched
# name. Force the C locale so the parsing below always sees English.
export LC_ALL=C

root="${1:?usage: check-elf-needed.sh <root> <providers-file> [report-file]}"
providers_file="${2:?usage: check-elf-needed.sh <root> <providers-file> [report-file]}"
report_file="${3:-}"
[[ -d "$root" && -f "$providers_file" ]] || exit 2

# Load the providers once into an exact-match table. The previous
# `grep -qE "^${soname}(=|$)"` treated the SONAME as a regular expression, so
# names containing regex metacharacters (libstdc++.so.6, libatk-1.0.so.0, ...)
# never matched, and it re-read the file for every NEEDED entry.
declare -A provided=()
while IFS= read -r line; do
  [[ -n "$line" ]] || continue
  provided["$line"]=1
  # pacman SONAME provides spell a version differently than the linker:
  # libx264.so=165-64 -> libx264.so.165
  if [[ "$line" =~ ^(.*[.]so)=([0-9][0-9.]*)(-[0-9]+)?$ ]]; then
    provided["${BASH_REMATCH[1]}.${BASH_REMATCH[2]}"]=1
  fi
done < "$providers_file"

missing=""
while IFS= read -r -d '' elf; do
  mapfile -t needed < <(
    readelf -d "$elf" 2>/dev/null |
      awk '/NEEDED/ {gsub(/[\[\]]/, "", $NF); print $NF}'
  )
  for soname in "${needed[@]}"; do
    [[ "$soname" == *.so* ]] || continue
    if [[ -z "${provided[$soname]:-}" ]]; then
      missing+="${soname} "
    fi
  done
done < <(
  find "$root" -type f -print0 |
    while IFS= read -r -d '' f; do
      [[ "$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]] &&
        printf '%s\0' "$f"
    done
)

missing="$(tr ' ' '\n' <<<"$missing" | sed '/^$/d' | sort -u | tr '\n' ' ')"
[[ -z "$report_file" ]] || printf '%s\n' "$missing" > "$report_file"
if [[ -n "$missing" ]]; then
  printf '%s\n' "$missing"
  exit 1
fi
exit 0
