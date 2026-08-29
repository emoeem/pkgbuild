#!/usr/bin/env bash
# 准备发布状态：优先下载现有 release 资产；还没有 release 时，回退到
# 旧 scheme 的 repo 分支快照作为初始仓库，保证首次发布不丢包。

set -Eeuo pipefail

for variable in REPOSITORY_DIR RELEASE_REPOSITORY RELEASE_TAG; do
    if [[ -z "${!variable:-}" ]]; then
        printf 'Missing required environment variable: %s\n' "$variable" >&2
        exit 2
    fi
done

readonly state_dir="${REPOSITORY_DIR}"
readonly release_repository="${RELEASE_REPOSITORY}"
readonly release_tag="${RELEASE_TAG}"
readonly legacy_branch="${LEGACY_BRANCH:-repo}"

mkdir -p "$state_dir"

if gh release view "$release_tag" --repo "$release_repository" >/dev/null 2>&1; then
    gh release download "$release_tag" \
        --repo "$release_repository" \
        --dir "$state_dir" \
        --clobber
    find "$state_dir" -maxdepth 1 -type f -printf '%f %k KiB\n' | sort
    exit 0
fi

printf 'Release %s not found; trying the legacy %s branch snapshot.\n' \
    "$release_tag" "$legacy_branch"

if ! git ls-remote --exit-code --heads \
    "https://github.com/${release_repository}.git" \
    "$legacy_branch" >/dev/null 2>&1; then
    printf 'No %s branch either; starting with an empty repository.\n' \
        "$legacy_branch"
    exit 0
fi

bootstrap_dir="$(mktemp -d)"
trap 'rm -rf "$bootstrap_dir"' EXIT
GIT_TERMINAL_PROMPT=0 git clone \
    --depth 1 \
    --branch "$legacy_branch" \
    "https://github.com/${release_repository}.git" \
    "$bootstrap_dir"

if [[ ! -d "${bootstrap_dir}/x86_64" ]]; then
    printf 'Legacy branch has no x86_64 directory; starting empty.\n'
    exit 0
fi

cp -a "${bootstrap_dir}/x86_64/." "$state_dir/"
find "$state_dir" -maxdepth 1 -type f -printf '%f %k KiB\n' | sort
