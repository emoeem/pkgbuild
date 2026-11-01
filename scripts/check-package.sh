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
            -name PKGBUILD \
            -printf '%h\n' |
            xargs -r -n1 basename |
            sort -u
    )
else
    package_names=("$@")
fi

if (( ${#package_names[@]} == 0 )); then
    printf 'No package directories containing PKGBUILD were found.\n' >&2
    exit 1
fi

for package_name in "${package_names[@]}"; do
    if [[ ! "$package_name" =~ ^[A-Za-z0-9@._+-]+$ ]]; then
        printf 'Invalid package directory name: %s\n' "$package_name" >&2
        exit 1
    fi

    package_dir="${repo_root}/packages/${package_name}"
    for file in PKGBUILD .SRCINFO; do
        if [[ ! -f "${package_dir}/${file}" ]]; then
            printf 'Missing %s for package %s.\n' "$file" "$package_name" >&2
            exit 1
        fi
    done

    bash -n "${package_dir}/PKGBUILD"

    if command -v makepkg >/dev/null 2>&1; then
        generated_srcinfo="$(mktemp)"
        makepkg_tmp="$(mktemp -d)"
        # makepkg verifies write access to BUILDDIR/PKGDEST even for
        # --printsrcinfo and defaults them to the package directory, which
        # may be read-only (CI mounts the workspace with :ro).
        if ! (
            cd "$package_dir" &&
            BUILDDIR="$makepkg_tmp" SRCDEST="$makepkg_tmp" \
                PKGDEST="$makepkg_tmp" LOGDEST="$makepkg_tmp" \
                makepkg --printsrcinfo >"$generated_srcinfo"
        ); then
            rm -rf "$makepkg_tmp"
            rm -f "$generated_srcinfo"
            printf 'Unable to generate .SRCINFO for %s.\n' "$package_name" >&2
            exit 1
        fi
        rm -rf "$makepkg_tmp"
        if ! diff -u "${package_dir}/.SRCINFO" "$generated_srcinfo"; then
            rm -f "$generated_srcinfo"
            printf 'PKGBUILD and .SRCINFO differ for %s.\n' "$package_name" >&2
            exit 1
        fi
        rm -f "$generated_srcinfo"
    fi

    while IFS= read -r source; do
        [[ "$source" == *"://"* || "$source" == *"::"* ]] && continue
        if [[ ! -f "${package_dir}/${source}" ]]; then
            printf '%s lists a missing local source: %s\n' \
                "$package_name" "$source" >&2
            exit 1
        fi
    done < <(
        awk -F ' = ' '$1 == "\tsource" { print $2 }' \
            "${package_dir}/.SRCINFO"
    )

    # A URL-declared source may be shadowed by a same-named file in the package
    # directory, which makepkg resolves before SRCDEST or the network. The cache
    # validator hashes that copy against the declaration; running it here makes
    # an AUR sync fail before committing, instead of dispatching a build that
    # can only die in the source validity check (ffmpeg-full 9.0.2-2.36).
    probe_cache="$(mktemp -d)"
    if ! validation="$(bash "${repo_root}/scripts/validate-source-cache.sh" \
        "$package_dir" "$probe_cache" 2>&1)"; then
        rmdir -- "$probe_cache" 2>/dev/null || true
        printf '%s\n' "$validation" >&2
        printf '%s has a source whose content does not match its declared checksum.\n' \
            "$package_name" >&2
        exit 1
    fi
    rmdir -- "$probe_cache" 2>/dev/null || true

    pkgbase="$(
        awk -F ' = ' '$1 == "pkgbase" { print $2; exit }' \
            "${package_dir}/.SRCINFO"
    )"
    pkgver="$(
        awk -F ' = ' '$1 == "\tpkgver" { print $2; exit }' \
            "${package_dir}/.SRCINFO"
    )"
    pkgrel="$(
        awk -F ' = ' '$1 == "\tpkgrel" { print $2; exit }' \
            "${package_dir}/.SRCINFO"
    )"

    if [[ -z "$pkgbase" || -z "$pkgver" || -z "$pkgrel" ]]; then
        printf 'Unable to read package metadata for %s.\n' "$package_name" >&2
        exit 1
    fi

    printf '%s %s-%s looks consistent.\n' "$pkgbase" "$pkgver" "$pkgrel"
done

bash -n "${repo_root}"/scripts/*.sh
