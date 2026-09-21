#!/usr/bin/env bash
set -Eeuo pipefail

root="${1:?usage: check-elf-needed.sh <root> <providers-file> [report-file]}"
providers_file="${2:?usage: check-elf-needed.sh <root> <providers-file> [report-file]}"
report_file="${3:-}"
[[ -d "$root" && -f "$providers_file" ]] || exit 2

missing=""
while IFS= read -r -d '' elf; do
  mapfile -t needed < <(
    readelf -d "$elf" 2>/dev/null |
      awk '/NEEDED/ {gsub(/[\[\]]/, "", $NF); print $NF}'
  )
  for soname in "${needed[@]}"; do
    [[ "$soname" == *.so* ]] || continue
    if ! grep -qE "^${soname}(=|$)" "$providers_file"; then
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
