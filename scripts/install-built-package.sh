#!/usr/bin/env bash

set -Eeuo pipefail

if (( $# == 0 )); then
    printf 'Usage: %s /path/to/package.pkg.tar.zst [...]\n' \
        "$(basename "$0")" >&2
    exit 2
fi

package_files=("$@")
for package_file in "${package_files[@]}"; do
    if [[ ! -f "$package_file" ]]; then
        printf 'Package file not found: %s\n' "$package_file" >&2
        exit 2
    fi
done

aur_helper=""
for candidate in paru yay; do
    if command -v "$candidate" >/dev/null 2>&1; then
        aur_helper="$candidate"
        break
    fi
done

if [[ -z "$aur_helper" ]]; then
    printf 'Install paru or yay first so AUR runtime dependencies can be resolved.\n' >&2
    exit 1
fi

mapfile -t dependencies < <(
    for package_file in "${package_files[@]}"; do
        bsdtar -xOf "$package_file" .PKGINFO
    done |
        awk -F ' = ' '$1 == "depend" { print $2 }' |
        sort -u
)

if (( ${#dependencies[@]} > 0 )); then
    "$aur_helper" -S --needed --asdeps --noconfirm "${dependencies[@]}"
fi

sudo pacman -U --noconfirm "${package_files[@]}"
