#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd
)"
readonly repo_root
readonly package_dir="${repo_root}/packages/ffmpeg-full"

temporary_dir="$(mktemp -d)"
trap 'rm -rf "$temporary_dir"' EXIT

git clone --depth 1 https://aur.archlinux.org/ffmpeg-full.git \
    "${temporary_dir}/aur"

rm -rf "$package_dir"
mkdir -p "$package_dir"

find "${temporary_dir}/aur" \
    -mindepth 1 \
    -maxdepth 1 \
    ! -name .git \
    -exec cp -a --target-directory="$package_dir" {} +

git -C "${temporary_dir}/aur" rev-parse HEAD > "${package_dir}/.aur-commit"

"${repo_root}/scripts/check-package.sh"
