#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd
)"
readonly repo_root

usage() {
    printf 'Usage: %s [--no-push] package-base\n' "$(basename "$0")"
}

push_changes=1
if [[ "${1:-}" == "--no-push" ]]; then
    push_changes=0
    shift
fi

if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    usage
    exit 0
fi

if (( $# != 1 )); then
    usage >&2
    exit 2
fi

package_name="$1"
package_dir="${repo_root}/packages/${package_name}"
package_path="packages/${package_name}"
removal_dir="${repo_root}/removals"
removal_file="${removal_dir}/${package_name}"
removal_path="removals/${package_name}"

if [[ ! "$package_name" =~ ^[A-Za-z0-9@._+-]+$ ]]; then
    printf 'Invalid package name: %s\n' "$package_name" >&2
    exit 2
fi

if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf 'This command must run from a Git checkout.\n' >&2
    exit 1
fi

current_branch="$(git -C "$repo_root" branch --show-current)"
if [[ "$current_branch" != "main" ]]; then
    printf 'Switch to the main branch before removing packages (current: %s).\n' \
        "${current_branch:-detached HEAD}" >&2
    exit 1
fi

printf 'Updating main from origin...\n'
git -C "$repo_root" pull --ff-only origin main

if [[ ! -f "${package_dir}/.SRCINFO" ]]; then
    printf '%s is not managed at %s.\n' "$package_name" "$package_dir" >&2
    exit 1
fi

if [[ -n "$(git -C "$repo_root" status --porcelain -- "$package_path")" ]]; then
    printf '%s contains local changes; refusing to remove it.\n' \
        "$package_path" >&2
    exit 1
fi

mapfile -t output_packages < <(
    awk -F ' = ' '$1 == "pkgname" { print $2 }' \
        "${package_dir}/.SRCINFO" |
        sort -u
)

if (( ${#output_packages[@]} == 0 )); then
    printf 'No pkgname entries were found in %s/.SRCINFO.\n' \
        "$package_path" >&2
    exit 1
fi

mkdir -p "$removal_dir"
printf '%s\n' "${output_packages[@]}" > "$removal_file"
git -C "$repo_root" rm -r -- "$package_path"
git -C "$repo_root" add -- "$removal_path"

git -C "$repo_root" commit \
    --message "package: remove ${package_name}" \
    -- "$package_path" "$removal_path"

if (( push_changes == 0 )); then
    printf 'Removed and committed %s locally. Push it with:\n' "$package_name"
    printf '  git push origin main\n'
    exit 0
fi

git -C "$repo_root" push origin HEAD:main
printf '\n%s was removed and pushed successfully.\n' "$package_name"
printf 'GitHub Actions will remove these repository packages:\n'
printf '  %s\n' "${output_packages[@]}"
