#!/usr/bin/env bash
set -Eeuo pipefail

package_name="${1:?usage: runtime-smoke-test.sh <package-name>}"
[[ "$package_name" != --* ]] || { echo 'package name required' >&2; exit 2; }

failures=0
count=0
mapfile -t files < <(
  pacman -Ql "$package_name" 2>/dev/null |
    awk '$2 ~ /^\// && $2 !~ /\/$/ {print $2}' |
    sort -u
)

for elf in "${files[@]}"; do
  [[ -f "$elf" ]] || continue
  [[ "$(head -c 4 "$elf" 2>/dev/null | od -An -tx1 | tr -d ' \n')" == "7f454c46" ]] || continue
  count=$((count + 1))
  if ldd "$elf" 2>&1 | grep -q 'not found'; then
    printf 'FAIL: unresolved runtime dependency: %s\n' "$elf" >&2
    ldd "$elf" >&2 || true
    failures=$((failures + 1))
  fi
done

printf 'Runtime smoke checked %d installed ELF object(s) for %s.\n' "$count" "$package_name"
if (( failures > 0 )); then
  printf 'Runtime smoke found %d unresolved ELF object(s).\n' "$failures" >&2
  exit 1
fi
printf 'Runtime smoke test passed for %s.\n' "$package_name"
