#!/usr/bin/env bash
set -Eeuo pipefail

package_dir="${1:?usage: prepare-build-source.sh <package-dir>}"
[[ -f "$package_dir/PKGBUILD" ]] || exit 2

if [[ "${BUMP_PKGREL:-false}" != "true" ]]; then
  exit 0
fi

current="$(awk -F= '/^pkgrel=/{gsub(/[[:space:]]/, "", $2); print $2; exit}' "$package_dir/PKGBUILD")"
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
