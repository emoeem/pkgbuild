#!/usr/bin/env bash
set -Eeuo pipefail

# Local-only repository policy: private packages first, Zen 3 toolchain only.
local_repo_name="${LOCAL_REPO_NAME:-emoeem}"
local_repo_dir="${LOCAL_REPO_DIR:-}"

if [[ -n "$local_repo_dir" ]]; then
    first="$(pacman-conf --repo-list | head -n1)"
    [[ "$first" == "$local_repo_name" ]] || {
        printf 'Repository order violation: expected %s first, got %s.\n' "$local_repo_name" "$first" >&2
        exit 2
    }
else
    if pacman-conf --repo-list | grep -Fxq "$local_repo_name"; then
        first="$(pacman-conf --repo-list | head -n1)"
        [[ "$first" == "$local_repo_name" ]] || {
            printf 'Unsafe local build: %s exists but is not first in pacman.conf.\n' "$local_repo_name" >&2
            exit 2
        }
    fi
fi

march="$(gcc -march=native -Q --help=target 2>/dev/null | awk '$1 == "-march=" {print $2}')"
[[ "$march" == "znver3" ]] || {
    printf 'Unexpected host compiler target: %s (expected znver3).\n' "$march" >&2
    exit 2
}

printf 'Build policy OK: repo=%s cpu=%s.\n' "$local_repo_name" "$march"
