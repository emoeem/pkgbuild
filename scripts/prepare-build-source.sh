#!/usr/bin/env bash
set -Eeuo pipefail

package_dir="${1:?usage: prepare-build-source.sh <package-dir>}"
[[ -f "$package_dir/PKGBUILD" ]] || exit 2

if [[ "${BUMP_PKGREL:-false}" != "true" ]]; then
  exit 0
fi

# pkgrel 行可能带行尾注释（quirc: `pkgrel=5  # emoeem overlay: quirc pkgrel bump`），
# 去掉空白和注释后再判断，否则 ABI 重建会在第一步就报 unsupported pkgrel。
current="$(awk -F= '/^pkgrel=/{v=$2; sub(/#.*/, "", v); gsub(/[[:space:]]/, "", v); print v; exit}' "$package_dir/PKGBUILD")"
if [[ "$current" =~ ^([0-9]+)$ ]]; then
  next="$((current + 1))"
elif [[ "$current" =~ ^([0-9]+)\.([0-9]+)$ ]]; then
  next="${BASH_REMATCH[1]}.$((BASH_REMATCH[2] + 1))"
else
  printf 'Cannot auto-bump unsupported pkgrel: %s\n' "$current" >&2
  exit 1
fi

sed -i -E "s/^pkgrel=.*/pkgrel=$next/" "$package_dir/PKGBUILD"
printf 'Automatic ABI rebuild: bumped pkgrel %s -> %s.\n' "$current" "$next"
(cd "$package_dir" && makepkg --printsrcinfo > .SRCINFO)
