#!/usr/bin/env bash

set -Euo pipefail

repo_root="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1
    pwd
)"
readonly repo_root

github_repository="${PKGBUILD_GITHUB_REPOSITORY:-emoeem/pkgbuild}"
pacman_repository="${PKGBUILD_PACMAN_REPOSITORY:-emoeem}"
default_make_jobs="${PKGBUILD_DEFAULT_MAKE_JOBS:-2}"

if [[ ! "$github_repository" =~ ^[^/[:space:]]+/[^/[:space:]]+$ ]]; then
    printf 'Invalid GitHub repository: %s\n' "$github_repository" >&2
    exit 2
fi
if [[ ! "$pacman_repository" =~ ^[A-Za-z0-9@._+-]+$ ]]; then
    printf 'Invalid pacman repository: %s\n' "$pacman_repository" >&2
    exit 2
fi
if [[ ! "$default_make_jobs" =~ ^[1-4]$ ]]; then
    printf 'Invalid default compiler job count: %s\n' \
        "$default_make_jobs" >&2
    exit 2
fi

readonly github_repository
readonly pacman_repository
readonly default_make_jobs

usage() {
    cat <<EOF
Usage: $(basename "$0") [--no-push]

Open the fzf package repository manager.

  --no-push  Start with automatic Git pushes disabled.
EOF
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

if (( $# != 0 )); then
    usage >&2
    exit 2
fi

for command_name in git fzf; do
    if ! command -v "$command_name" >/dev/null 2>&1; then
        printf '%s is required.\n' "$command_name" >&2
        if [[ "$command_name" == "fzf" ]]; then
            printf 'Install it with: sudo pacman -S fzf\n' >&2
        fi
        exit 1
    fi
done

if ! git -C "$repo_root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    printf '%s is not a Git checkout.\n' "$repo_root" >&2
    exit 1
fi

readonly -a fzf_options=(
    --height=85%
    --layout=reverse
    --border
    --cycle
    --info=inline
)

pause_after_action() {
    printf '\n'
    read -r -p 'Press Enter to return to the menu...' _ || true
}

prompt_value() {
    local label="$1"
    local value

    read -r -p "${label}: " value || return 1
    printf '%s\n' "$value"
}

managed_packages() {
    find "${repo_root}/packages" \
        -mindepth 2 \
        -maxdepth 2 \
        -type f \
        -name PKGBUILD \
        -printf '%h\n' |
        xargs -r -n1 basename |
        sort -u
}

aur_packages() {
    find "${repo_root}/packages" \
        -mindepth 2 \
        -maxdepth 2 \
        -type f \
        -name .aur-url \
        -printf '%h\n' |
        xargs -r -n1 basename |
        sort -u
}

select_one() {
    local prompt="$1"
    shift

    printf '%s\n' "$@" |
        fzf "${fzf_options[@]}" --prompt="${prompt}> "
}

select_managed_package() {
    managed_packages |
        fzf "${fzf_options[@]}" --prompt='Package> '
}

select_managed_packages() {
    managed_packages |
        fzf \
            "${fzf_options[@]}" \
            --multi \
            --bind='ctrl-a:select-all,ctrl-d:deselect-all' \
            --header='Tab: toggle  Ctrl-A: all  Ctrl-D: none' \
            --prompt='Packages> '
}

select_aur_packages() {
    {
        printf '%s\n' all
        aur_packages
    } |
        fzf \
            "${fzf_options[@]}" \
            --multi \
            --bind='ctrl-a:select-all,ctrl-d:deselect-all' \
            --header='Choose all, or select packages with Tab' \
            --prompt='AUR sync> '
}

require_gh() {
    if ! command -v gh >/dev/null 2>&1; then
        printf 'GitHub CLI is required. Install it with: sudo pacman -S github-cli\n' \
            >&2
        return 1
    fi
}

pull_main() {
    git -C "$repo_root" pull --ff-only origin main
}

add_aur_package() {
    local package_name
    local -a arguments=()

    package_name="$(prompt_value 'AUR package base')" || return
    [[ -n "$package_name" ]] || return
    (( push_changes == 0 )) && arguments+=(--no-push)
    "${repo_root}/scripts/add-aur-package.sh" \
        "${arguments[@]}" \
        "$package_name"
}

add_custom_package() {
    local package_name git_url
    local -a arguments=()

    package_name="$(prompt_value 'Package base')" || return
    [[ -n "$package_name" ]] || return
    git_url="$(prompt_value 'PKGBUILD Git URL')" || return
    [[ -n "$git_url" ]] || return
    (( push_changes == 0 )) && arguments+=(--no-push)
    "${repo_root}/scripts/add-aur-package.sh" \
        "${arguments[@]}" \
        "$package_name" \
        "$git_url"
}

remove_package() {
    local package_name confirmation
    local -a arguments=()

    package_name="$(select_managed_package)" || return
    [[ -n "$package_name" ]] || return
    confirmation="$(
        select_one \
            "Remove ${package_name}" \
            'Cancel' \
            'Remove from repository'
    )" || return
    [[ "$confirmation" == 'Remove from repository' ]] || return

    (( push_changes == 0 )) && arguments+=(--no-push)
    "${repo_root}/scripts/remove-package.sh" \
        "${arguments[@]}" \
        "$package_name"
}

sync_aur_sources() {
    local package_name selection package_csv
    local -a packages=()

    require_gh || return
    mapfile -t packages < <(select_aur_packages)
    (( ${#packages[@]} > 0 )) || return

    selection="selected"
    for package_name in "${packages[@]}"; do
        if [[ "$package_name" == "all" ]]; then
            selection="all"
            break
        fi
    done

    if [[ "$selection" == "all" ]]; then
        package_csv="all"
    else
        package_csv="$(IFS=,; printf '%s' "${packages[*]}")"
    fi

    gh workflow run sync.yml \
        --repo "$github_repository" \
        --ref main \
        -f "packages=${package_csv}"
    printf 'AUR synchronization requested for: %s\n' "$package_csv"
}

build_packages() {
    local candidate make_jobs package_csv jobs_choice
    local -a jobs_options=("${default_make_jobs} (default)")
    local -a packages=()

    require_gh || return
    mapfile -t packages < <(select_managed_packages)
    (( ${#packages[@]} > 0 )) || return

    for candidate in 1 2 3 4; do
        [[ "$candidate" == "$default_make_jobs" ]] ||
            jobs_options+=("$candidate")
    done
    jobs_choice="$(
        select_one 'Compiler jobs' "${jobs_options[@]}"
    )" || return
    make_jobs="${jobs_choice%% *}"
    package_csv="$(IFS=,; printf '%s' "${packages[*]}")"

    gh workflow run build.yml \
        --repo "$github_repository" \
        --ref main \
        -f "packages=${package_csv}" \
        -f "make_jobs=${make_jobs}"
    printf 'Build requested for: %s (make jobs: %s)\n' \
        "$package_csv" "$make_jobs"
}

update_local_repository() {
    if ! command -v emoeem-update >/dev/null 2>&1; then
        printf 'emoeem-update is not installed. Run ./client/install.sh first.\n' \
            >&2
        return 1
    fi

    emoeem-update
    pacman -Sl "$pacman_repository"
}

install_repository_package() {
    local package_name
    local -a packages=()

    mapfile -t packages < <(
        pacman -Sl "$pacman_repository" 2>/dev/null |
            awk '{ print $2 }' |
            sort -u
    )
    if (( ${#packages[@]} == 0 )); then
        printf 'No packages are currently available from %s.\n' \
            "$pacman_repository" >&2
        return 1
    fi

    package_name="$(
        select_one 'Install package' "${packages[@]}"
    )" || return
    [[ -n "$package_name" ]] || return
    sudo pacman -S "${pacman_repository}/${package_name}"
}

show_recent_actions() {
    local run_id selected
    local -a runs=()

    require_gh || return
    mapfile -t runs < <(
        gh run list \
            --repo "$github_repository" \
            --limit 30 \
            --json databaseId,status,conclusion,workflowName,displayTitle \
            --jq \
            '.[] | [.databaseId, .status, (.conclusion // "-"), .workflowName, .displayTitle] | @tsv'
    )
    if (( ${#runs[@]} == 0 )); then
        printf 'No GitHub Actions runs were found.\n'
        return
    fi

    selected="$(
        printf '%s\n' "${runs[@]}" |
            fzf \
                "${fzf_options[@]}" \
                --delimiter=$'\t' \
                --with-nth=2.. \
                --prompt='Actions run> '
    )" || return
    run_id="${selected%%$'\t'*}"
    gh run view "$run_id" --repo "$github_repository"
}

while true; do
    branch="$(git -C "$repo_root" branch --show-current)"
    package_count="$(managed_packages | wc -l)"
    install_label="Install package from ${pacman_repository}"
    if (( push_changes == 1 )); then
        push_label='ON'
    else
        push_label='OFF'
    fi

    action="$(
        select_one \
            "${github_repository} | ${branch:-detached} | ${package_count} packages | push ${push_label}" \
            'Add AUR package' \
            'Add package from custom Git' \
            'Remove package from repository' \
            'Sync AUR sources on GitHub' \
            'Build packages on GitHub' \
            'Update local pacman repository' \
            "$install_label" \
            'Show recent GitHub Actions' \
            'Pull source branch' \
            "Toggle automatic push (${push_label})" \
            'Exit'
    )" || exit 0

    action_status=0
    case "$action" in
        'Add AUR package')
            add_aur_package || action_status=$?
            ;;
        'Add package from custom Git')
            add_custom_package || action_status=$?
            ;;
        'Remove package from repository')
            remove_package || action_status=$?
            ;;
        'Sync AUR sources on GitHub')
            sync_aur_sources || action_status=$?
            ;;
        'Build packages on GitHub')
            build_packages || action_status=$?
            ;;
        'Update local pacman repository')
            update_local_repository || action_status=$?
            ;;
        "$install_label")
            install_repository_package || action_status=$?
            ;;
        'Show recent GitHub Actions')
            show_recent_actions || action_status=$?
            ;;
        'Pull source branch')
            pull_main || action_status=$?
            ;;
        Toggle*)
            if (( push_changes == 1 )); then
                push_changes=0
            else
                push_changes=1
            fi
            continue
            ;;
        'Exit')
            exit 0
            ;;
    esac

    if (( action_status != 0 )); then
        printf '\nAction failed with status %d.\n' "$action_status" >&2
    fi
    pause_after_action
done
