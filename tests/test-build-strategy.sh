#!/usr/bin/env bash
# 构建策略库（scripts/lib/build-strategy.sh）与消费点判据的测试（Phase 3）。
#
# 钉住三件事：
#   1. lib 的解析：四值合法、注释与空行跳过、非法/缺失输出为空且返回非零；
#   2. fail-safe 判据的唯一方向：只有**明确声明**的 binary-repack/data 才
#      defer 给上游；缺失或非法一律按可本地重建处理——三个消费点（依赖版本
#      漂移、SONAME 检测、dispatch）对「策略不明」不允许各自假设；
#   3. 真实树：packages/ 下 15 个包全部声明了合法策略，且 binary-repack/data
#      的成员与可本地重建集合互斥（dispatch 端 IGNORE 的对象清单）。
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# shellcheck source=../scripts/lib/build-strategy.sh
source "$root/scripts/lib/build-strategy.sh"

printf '%s\n' '1: build_strategy_of parses the documented format'
mk_pkg() { # <name> <file-content-or-empty>
    local dir="$tmp/$1"
    mkdir -p "$dir"
    [[ -n "$2" ]] && printf '%s\n' "$2" > "$dir/.build-strategy"
    printf '%s\n' "$dir"
}
d="$(mk_pkg src "$(printf 'source\n# compiled from source\n')")"
[[ "$(build_strategy_of "$d")" == source ]] || fail 'source not parsed'

for value in source binary-repack vcs data; do
    d="$(mk_pkg "ok-$value" "$value")"
    [[ "$(build_strategy_of "$d")" == "$value" ]] || fail "value $value not parsed"
done

d="$(mk_pkg leading-comment "$(printf '# why\n\nbinary-repack\n')")"
[[ "$(build_strategy_of "$d")" == binary-repack ]] || fail 'comment/blank lines not skipped'

d="$(mk_pkg bad 'sometimes')"
[[ -z "$(build_strategy_of "$d" 2>/dev/null || true)" ]] || fail 'an unknown value must not parse'
d="$(mk_pkg empty '')"
[[ -z "$(build_strategy_of "$d" 2>/dev/null || true)" ]] || fail 'an empty file must not parse'
d="$(mk_pkg absent '')"
rm -f "$d/.build-strategy"
[[ -z "$(build_strategy_of "$d" 2>/dev/null || true)" ]] || fail 'a missing file must not parse'
echo 'ok: lib parsing (four values, comments, unknown/empty/missing)'

printf '%s\n' '2: the fail-safe criterion only honors explicit declarations'
build_strategy_defers_to_upstream binary-repack || fail 'binary-repack must defer to upstream'
build_strategy_defers_to_upstream data || fail 'data must defer to upstream'
build_strategy_defers_to_upstream source && fail 'source must not defer'
build_strategy_defers_to_upstream vcs && fail 'vcs must not defer'
build_strategy_defers_to_upstream "" && fail 'an unknown strategy must NOT defer (fail-safe: rebuild)'
build_strategy_defers_to_upstream garbage && fail 'a garbage strategy must NOT defer'
echo 'ok: only binary-repack/data defer; unknown strategies rebuild (fail-safe)'

printf '%s\n' '3: the real tree declares exactly one legal strategy per package'
shopt -s nullglob
declared=0
for pkg_dir in "$root"/packages/*/; do
    name="$(basename "$pkg_dir")"
    value="$(build_strategy_of "$pkg_dir")" ||
        fail "$name: missing or illegal .build-strategy in the real tree"
    declared=$((declared + 1))
done
shopt -u nullglob
(( declared == 14 )) || fail "expected 14 packages with a strategy, found $declared"
echo "ok: $declared/14 packages declare a legal strategy"

printf '%s\n' '4: repack/data members match the audit classification'
expected_repack='dsh-desktop-linux filee-bin trae-cn-appimage vapoursynth-plugin-mlrt-ncnn-runtime'
expected_data='sing-box-rule-sets'
actual="$(for pkg_dir in "$root"/packages/*/; do
    value="$(build_strategy_of "$pkg_dir")" || continue
    if build_strategy_defers_to_upstream "$value"; then
        basename "$pkg_dir"
    fi
done | sort | paste -sd' ' -)"
[[ "$actual" == "$(printf '%s\n%s' "$expected_data" "$expected_repack" | tr ' ' '\n' | sort | paste -sd' ' -)" ]] ||
    fail "repack/data set drifted from the audit: $actual"
echo 'ok: repack/data membership matches reports/pkgbuild-optimization/package-strategy-audit.md'

printf 'all build-strategy cases passed\n'
