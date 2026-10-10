#!/usr/bin/env bash
# 把仓库自带的 .githooks 目录接到本地 git 上，让 pre-commit 钩子在每次提交前跑
# scripts/run-static-checks.sh（与 check.yml 的静态关卡同一份清单）。
#
# 这是每个开发者在自己克隆里跑一次的一次性设置，不改变仓库内容；撤销：
#   git config --unset core.hooksPath
set -Eeuo pipefail

repo_root="$(
    cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1 &&
        pwd
)"
readonly repo_root

hook="${repo_root}/.githooks/pre-commit"
if [[ ! -f "$hook" ]]; then
    printf 'ERROR: %s is missing\n' "$hook" >&2
    exit 1
fi
chmod +x "$hook" "${repo_root}/scripts/run-static-checks.sh"

git -C "$repo_root" config core.hooksPath .githooks

printf 'core.hooksPath = %s\n' "$(git -C "$repo_root" config --get core.hooksPath)"
printf 'Pre-commit hook installed: every commit now runs scripts/run-static-checks.sh.\n'
printf 'Skip it once with: EMO_SKIP_STATIC_CHECKS=1 git commit ...\n'
printf 'Remove it with: git config --unset core.hooksPath\n'
