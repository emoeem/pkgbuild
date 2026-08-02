#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd
)"
readonly repo_root
readonly package_dir="${repo_root}/packages/ffmpeg-full"

required_files=(
    ".SRCINFO"
    "PKGBUILD"
    "LICENSE"
    "010-ffmpeg-add-svt-hevc.patch"
    "030-ffmpeg-add-svt-vp9.patch"
    "040-ffmpeg-add-av_stream_get_first_dts-for-chromium.patch"
    "050-ffmpeg-fix-cuda-nvcc-with-gcc14.patch"
    "060-ffmpeg-whisper.cpp-fix-pkgconfig.patch"
)

for file in "${required_files[@]}"; do
    if [[ ! -f "${package_dir}/${file}" ]]; then
        printf 'Missing required package file: %s\n' "$file" >&2
        exit 1
    fi
done

bash -n "${package_dir}/PKGBUILD"
bash -n "${repo_root}"/scripts/*.sh

pkgver="$(awk -F ' = ' '$1 == "\tpkgver" { print $2; exit }' \
    "${package_dir}/.SRCINFO")"
pkgrel="$(awk -F ' = ' '$1 == "\tpkgrel" { print $2; exit }' \
    "${package_dir}/.SRCINFO")"

if [[ -z "$pkgver" || -z "$pkgrel" ]]; then
    printf 'Unable to read pkgver/pkgrel from .SRCINFO\n' >&2
    exit 1
fi

grep -Fxq "pkgver=${pkgver}" "${package_dir}/PKGBUILD"
grep -Fxq "pkgrel=${pkgrel}" "${package_dir}/PKGBUILD"

while IFS= read -r source; do
    [[ "$source" == *"://"* || "$source" == *"::"* ]] && continue
    if [[ ! -f "${package_dir}/${source}" ]]; then
        printf 'Local source listed in .SRCINFO is missing: %s\n' "$source" >&2
        exit 1
    fi
done < <(
    awk -F ' = ' '$1 == "\tsource" { print $2 }' \
        "${package_dir}/.SRCINFO"
)

printf 'ffmpeg-full %s-%s package files look consistent.\n' "$pkgver" "$pkgrel"
