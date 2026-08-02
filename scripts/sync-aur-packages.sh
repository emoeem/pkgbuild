#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd
)"
readonly repo_root

if (( $# == 0 )); then
    mapfile -t package_names < <(
        find "${repo_root}/packages" \
            -mindepth 2 \
            -maxdepth 2 \
            -type f \
            -name .aur-url \
            -printf '%h\n' |
            xargs -r -n1 basename |
            sort -u
    )
else
    package_names=("$@")
fi

if (( ${#package_names[@]} == 0 )); then
    printf 'No AUR-managed packages were selected.\n' >&2
    exit 1
fi

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

for package_name in "${package_names[@]}"; do
    package_dir="${repo_root}/packages/${package_name}"
    aur_url_file="${package_dir}/.aur-url"

    if [[ ! -f "$aur_url_file" ]]; then
        printf '%s is not AUR-managed because .aur-url is missing.\n' \
            "$package_name" >&2
        exit 1
    fi

    aur_url="$(<"$aur_url_file")"
    checkout_dir="${temporary_dir}/${package_name}"
    git clone --depth 1 "$aur_url" "$checkout_dir"
    aur_commit="$(git -C "$checkout_dir" rev-parse HEAD)"

    rm -rf "$package_dir"
    mkdir -p "$package_dir"
    find "$checkout_dir" \
        -mindepth 1 \
        -maxdepth 1 \
        ! -name .git \
        -exec cp -a --target-directory="$package_dir" {} +

    printf '%s\n' "$aur_url" > "${package_dir}/.aur-url"
    printf '%s\n' "$aur_commit" > "${package_dir}/.aur-commit"
done

"${repo_root}/scripts/check-package.sh" "${package_names[@]}"
