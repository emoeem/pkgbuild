#!/usr/bin/env bash
set -Eeuo pipefail

# Local-only repository policy: the private repository, when it is configured at
# all, must be authoritative; and the toolchain must target Zen 3.
#
# "When it is configured" is the operative clause. configure-build-repo.sh only
# writes [emoeem] into pacman.conf when the mounted repository directory holds
# at least one *.pkg.tar.zst. A package with no private dependencies - a
# self-contained upstream tarball such as filee-bin - mounts an empty directory
# on purpose, so no [emoeem] stanza exists and the first repository is legitimately
# cachyos-v3. Demanding that an absent repository be first made every such build
# abort with "Repository order violation: expected emoeem first, got cachyos-v3"
# (Track Filee releases run 39593696778).
#
# The safety property this gate exists for is unchanged: a private package must
# not be shadowed by a distribution build of the same name. That requires the
# repository to exist. So ordering is enforced whenever [emoeem] appears in
# pacman.conf, and a populated repository directory that failed to reach
# pacman.conf is still refused outright - that is the case where a distro
# package could silently win.

local_repo_name="${LOCAL_REPO_NAME:-emoeem}"
local_repo_dir="${LOCAL_REPO_DIR:-}"

repo_list="$(pacman-conf --repo-list)"

if grep -Fxq "$local_repo_name" <<< "$repo_list"; then
    first="$(head -n1 <<< "$repo_list")"
    [[ "$first" == "$local_repo_name" ]] || {
        printf 'Repository order violation: expected %s first, got %s.\n' \
            "$local_repo_name" "$first" >&2
        exit 2
    }
elif [[ -n "$local_repo_dir" ]]; then
    shopt -s nullglob
    packages=("$local_repo_dir"/*.pkg.tar.zst)
    shopt -u nullglob
    if (( ${#packages[@]} > 0 )); then
        printf 'Repository %s holds %d package(s) but is not configured in pacman.conf.\n' \
            "$local_repo_dir" "${#packages[@]}" >&2
        exit 2
    fi
    printf 'Local repository %s is empty; building without it.\n' "$local_repo_dir"
fi

march="znver3"
if ! gcc -march=znver3 -mtune=znver3 -O3 -x c -c /dev/null -o /tmp/emo-build-policy-test.o >/dev/null 2>&1; then
    printf 'Compiler cannot accept required Zen 3 target: %s.\n' "$march" >&2
    exit 2
fi
rm -f /tmp/emo-build-policy-test.o

printf 'Build policy OK: repo=%s target=%s.\n' "$local_repo_name" "$march"
