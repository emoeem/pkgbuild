#!/usr/bin/env bash
set -Eeuo pipefail

package_dir="${1:?usage: prepare-build-source.sh <package-dir>}"
[[ -f "$package_dir/PKGBUILD" ]] || exit 2

# pkgrel 递增策略的单一实现（解析、递增、写回、跳过标记都在那里定义）：
# pkgrel-floor.sh 与 auto-repair.sh 的 bump_pkgrel 走同一套判断，任何行为
# 改动只发生在 lib 一处。
script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/pkgrel-policy.sh
source "${script_dir}/lib/pkgrel-policy.sh"

if [[ "${BUMP_PKGREL:-false}" != "true" ]]; then
  exit 0
fi

# Repack 包显式退出递增（.pkgrel-floor-skip）：payload 与已发布版本逐字节
# 相同，bump 只会制造一次「上游没动、版本号自己变了」的假升级。此前只有
# pkgrel-floor.sh 认这个标记，ABI 重建入口不认，dsh-desktop-linux 这类包
# 仍被自动抬档（Phase 1 修复，reports/pkgbuild-optimization/pkgrel-flow-audit.md
# §2.1）。退出后同版本重建由发布闸门的 already_published 路径处理，不静默。
if pkgrel_policy_skip "$package_dir"; then
  printf 'prepare-build-source: %s opts out via .pkgrel-floor-skip; nothing to bump.\n' \
      "$(basename "$package_dir")"
  exit 0
fi

current="$(pkgrel_policy_parse "$package_dir/PKGBUILD")"
next="$(pkgrel_policy_next "$current")" || {
  printf 'Cannot auto-bump unsupported pkgrel: %s\n' "$current" >&2
  exit 1
}
pkgrel_policy_apply "$package_dir" "$next"
printf 'Automatic ABI rebuild: bumped pkgrel %s -> %s.\n' "$current" "$next"
