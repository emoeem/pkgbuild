#!/usr/bin/env bash

set -Eeuo pipefail

repo_root="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
    pwd
)"
readonly repo_root

usage() {
    printf 'Usage: %s [--no-push] package-name [aur-git-url]\n' \
        "$(basename "$0")"
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

if (( $# < 1 || $# > 2 )); then
    usage >&2
    exit 2
fi

package_name="$1"
aur_url="${2:-https://aur.archlinux.org/${package_name}.git}"
package_dir="${repo_root}/packages/${package_name}"
package_path="packages/${package_name}"
removal_file="${repo_root}/removals/${package_name}"
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
    printf 'Switch to the main branch before adding packages (current: %s).\n' \
        "${current_branch:-detached HEAD}" >&2
    exit 1
fi

printf 'Updating main from origin...\n'
git -C "$repo_root" pull --ff-only origin main

if [[ -e "$package_dir" ]]; then
    printf '%s is already managed at %s.\n' \
        "$package_name" "$package_dir" >&2
    printf 'To refresh it now, run: ./scripts/sync-aur-packages.sh %s\n' \
        "$package_name" >&2
    exit 1
fi

mkdir -p "$package_dir"
printf '%s\n' "$aur_url" > "${package_dir}/.aur-url"
"${repo_root}/scripts/sync-aur-packages.sh" "$package_name"

commit_paths=("$package_path")
if git -C "$repo_root" ls-files --error-unmatch "$removal_path" \
    >/dev/null 2>&1; then
    rm -f "$removal_file"
    commit_paths+=("$removal_path")
fi

git -C "$repo_root" add --all -- "${commit_paths[@]}"
if git -C "$repo_root" diff --cached --quiet -- "${commit_paths[@]}"; then
    printf 'No files were added for %s.\n' "$package_name" >&2
    exit 1
fi

git -C "$repo_root" commit \
    --message "package: add ${package_name}" \
    -- "${commit_paths[@]}"

if (( push_changes == 0 )); then
    printf 'Added and committed %s locally. Push it with:\n' "$package_name"
    printf '  git push origin main\n'
    exit 0
fi

git -C "$repo_root" push origin HEAD:main
printf '\n%s was added and pushed successfully.\n' "$package_name"
printf 'GitHub Actions will build it and update the repo branch automatically.\n'
