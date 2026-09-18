#!/usr/bin/env bash

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

while IFS= read -r spec; do
    [[ "$spec" == *"git+"* ]] || continue

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
done < <(awk -F ' = ' '$1 == "\tsource" { print $2 }' "${package_dir}/.SRCINFO")
