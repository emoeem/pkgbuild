#!/usr/bin/env bash
# Validate the restored source cache against what the package declares.
#
# The cache is a build accelerator, never a source of truth: a file that the
# cache returned but that no longer matches the package's declared checksum
# must not be handed to makepkg. makepkg prints `-> Found <name>` for any file
# already sitting in SRCDEST and does NOT re-fetch it, so a stale entry fails
# the validity check in exactly the same way a genuinely changed upstream
# source would -- and re-running the build can never tell the two apart.
#
# This script runs before the build and settles the question by content:
#
#   * Git sources        -- the cached remote must be the declared remote
#                           (unchanged behaviour).
#   * Remote file sources -- the cached copy is hashed. A mismatch means the
#                           cache is stale, so the entry is deleted and the
#                           build re-fetches it in this same run. Self-healing,
#                           no retry, no human.
#   * Local file sources  -- the repository's own copy is hashed. A mismatch
#                           there is a defect in the repository (the declared
#                           checksum does not describe the committed file), not
#                           something a cache can repair, so the script fails
#                           fast with the file named instead of letting makepkg
#                           fail ten minutes later with a generic message.
#
# Usage: validate-source-cache.sh <package-dir> <source-cache-dir>
# Exit:  0 clean (or healed), 1 repository defect, 2 usage error.

set -Eeuo pipefail

if (( $# != 2 )); then
    printf 'Usage: %s <package-dir> <source-cache-dir>\n' "$0" >&2
    exit 2
fi

package_dir="$1"
source_cache_dir="$2"

[[ -f "${package_dir}/.SRCINFO" ]] || {
    printf 'Missing .SRCINFO: %s\n' "${package_dir}" >&2
    exit 2
}

canonical_git_url() {
    local url="$1"
    url="${url%%#*}"
    url="${url%/}"
    printf '%s' "${url%.git}"
}

# makepkg's file name for a source entry: `name::url` names it explicitly,
# otherwise it is the last path component of the URL (or of the local path).
source_filename() {
    local spec="$1"
    if [[ "$spec" == *"::"* ]]; then
        printf '%s' "${spec%%::*}"
        return
    fi
    local path="${spec#git+}"
    path="${path%%#*}"
    path="${path%%\?*}"
    printf '%s' "${path##*/}"
}

# Hash a file with the one algorithm the package declares. Every .SRCINFO in
# this repository uses sha256sums; an unknown or absent declaration returns an
# empty string so the caller can skip instead of guessing.
file_digest() {
    local file="$1" sum="$2"
    case "${#sum}" in
        64) sha256sum -- "$file" | cut -d' ' -f1 ;;
        128) sha512sum -- "$file" | cut -d' ' -f1 ;;
        32) md5sum -- "$file" | cut -d' ' -f1 ;;
        *) printf '' ;;
    esac
}

# `source` and `sha256sums` are positional arrays aligned by index.
mapfile -t sources < <(awk -F ' = ' '$1 ~ /^[[:space:]]*source$/ { print $2 }' "${package_dir}/.SRCINFO")
mapfile -t sums < <(awk -F ' = ' '$1 ~ /^[[:space:]]*sha256sums$/ { print $2 }' "${package_dir}/.SRCINFO")

if (( ${#sums[@]} > 0 && ${#sums[@]} != ${#sources[@]} )); then
    printf 'WARNING: %s declares %s source(s) but %s sha256sums entry/entries; skipping per-file checks.\n' \
        "${package_dir}" "${#sources[@]}" "${#sums[@]}" >&2
    sums=()
fi

checked=0
healed=0
verified_local=0
defects=0

for (( i = 0; i < ${#sources[@]}; i++ )); do
    spec="${sources[i]}"
    [[ -n "$spec" ]] || continue
    expected="${sums[i]:-}"

    if [[ "$spec" == *"git+"* ]]; then
        if [[ "$spec" == *"::git+"* ]]; then
            name="${spec%%::*}"
            url="${spec#*::git+}"
        else
            url="${spec#git+}"
            name="${url%%#*}"
            name="${name##*/}"
            name="${name%.git}"
        fi

        cache_path="${source_cache_dir}/${name}"
        [[ -e "$cache_path" ]] || continue

        if [[ ! -d "$cache_path/.git" ]]; then
            printf 'Removing non-git source cache collision: %s\n' "$cache_path"
            rm -rf "$cache_path"
            healed=$(( healed + 1 ))
            continue
        fi

        remote="$(git -C "$cache_path" remote get-url origin 2>/dev/null || true)"
        if [[ "$(canonical_git_url "$remote")" == "$(canonical_git_url "$url")" ]]; then
            continue
        fi

        printf 'Removing stale git source cache: %s\n' "$cache_path"
        printf '  cached: %s\n' "$remote"
        printf '  needed: %s\n' "${url%%#*}"
        rm -rf "$cache_path"
        healed=$(( healed + 1 ))
        continue
    fi

    name="$(source_filename "$spec")"
    [[ -n "$name" ]] || continue

    if [[ "$spec" == *"://"* ]]; then
        # Remote file: the cached copy is what makepkg would hash.
        cache_path="${source_cache_dir}/${name}"
        [[ -f "$cache_path" ]] || continue
        [[ -n "$expected" && "$expected" != "SKIP" ]] || continue

        actual="$(file_digest "$cache_path" "$expected")"
        checked=$(( checked + 1 ))
        if [[ -z "$actual" ]]; then
            printf 'WARNING: cannot hash %s with the declared checksum format; leaving it alone.\n' "$cache_path" >&2
            continue
        fi
        if [[ "$actual" == "$expected" ]]; then
            continue
        fi

        printf 'Removing stale source cache entry: %s\n' "$cache_path"
        printf '  cached:  %s\n' "$actual"
        printf '  declared:%s\n' "$expected"
        printf '  the build will re-fetch it from %s\n' "${spec#*::}"
        rm -f "$cache_path"
        healed=$(( healed + 1 ))
        continue
    fi

    # Local file: the repository's own copy is authoritative (makepkg prefers
    # $startdir over $SRCDEST), so a mismatch here is a repository defect.
    local_path="${package_dir}/${name}"
    [[ -f "$local_path" ]] || continue
    [[ -n "$expected" && "$expected" != "SKIP" ]] || continue

    actual="$(file_digest "$local_path" "$expected")"
    verified_local=$(( verified_local + 1 ))
    [[ -n "$actual" ]] || continue
    if [[ "$actual" != "$expected" ]]; then
        printf 'ERROR: %s does not match its declared checksum.\n' "$local_path" >&2
        printf '  actual:   %s\n' "$actual" >&2
        printf '  declared: %s\n' "$expected" >&2
        printf 'The file is part of this repository and the checksum describes a different revision of it.\n' >&2
        defects=$(( defects + 1 ))
    fi
done

if (( defects > 0 )); then
    printf 'Source cache validation failed: %s local source(s) do not match their declared checksum.\n' "$defects" >&2
    exit 1
fi

if (( healed > 0 || checked > 0 || verified_local > 0 )); then
    printf 'Source cache: %s cached file(s) verified, %s stale entry/entries removed, %s local source(s) verified.\n' \
        "$checked" "$healed" "$verified_local"
fi
