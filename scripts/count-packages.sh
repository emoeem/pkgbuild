#!/usr/bin/env bash
# Ensure README's maintained package-base count matches source package directories.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
count="$(find "$root/packages" -mindepth 2 -maxdepth 2 -type f -name PKGBUILD -printf '%h\n' | sort -u | wc -l)"
count="$(printf '%s' "$count" | tr -d '[:space:]')"
readme_count="$(sed -nE 's/^当前维护 ([0-9]+) 个 package base。$/\1/p' "$root/README.md")"
if [[ ! "$readme_count" =~ ^[0-9]+$ ]]; then
    printf 'README.md must contain exactly one maintained package-base count.\n' >&2
    exit 1
fi
if [[ "$readme_count" != "$count" ]]; then
    printf 'Package base count mismatch: README=%s, packages/=%s\n' "$readme_count" "$count" >&2
    exit 1
fi
printf 'Package base count matches README: %s\n' "$count"
