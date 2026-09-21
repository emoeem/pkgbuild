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

march="znver3"
if ! gcc -march=znver3 -mtune=znver3 -O3 -x c -c /dev/null -o /tmp/emo-build-policy-test.o >/dev/null 2>&1; then
    printf 'Compiler cannot accept required Zen 3 target: %s.\n' "$march" >&2
    exit 2
fi
rm -f /tmp/emo-build-policy-test.o

printf 'Build policy OK: repo=%s target=%s.\n' "$local_repo_name" "$march"
