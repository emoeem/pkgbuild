#!/usr/bin/env bash

set -Eeuo pipefail

if (( $# < 1 || $# > 2 )); then
    printf 'Usage: %s package-name [aur-git-url]\n' "$(basename "$0")" >&2
    exit 2
fi

repo_root="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd
)"
readonly repo_root

package_name="$1"
aur_url="${2:-https://aur.archlinux.org/${package_name}.git}"
package_dir="${repo_root}/packages/${package_name}"

if [[ ! "$package_name" =~ ^[A-Za-z0-9@._+-]+$ ]]; then
    printf 'Invalid package name: %s\n' "$package_name" >&2
    exit 2
fi

if [[ -e "$package_dir" ]]; then
    printf 'Package directory already exists: %s\n' "$package_dir" >&2
    exit 1
fi

mkdir -p "$package_dir"
printf '%s\n' "$aur_url" > "${package_dir}/.aur-url"
"${repo_root}/scripts/sync-aur-packages.sh" "$package_name"
