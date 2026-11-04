#!/usr/bin/env bash
# sync-aur-packages.sh 按包隔离失败的行为判据。
#
# 背景（2026-11-05，runs #103/#104）：scx-scheds-git 的 overlay 落空让整轮
# sync 连红四天，其余包的 AUR 更新被一起扣住。同步的价值在于"别的包照常前
# 进"，所以脚本必须：失败包保持已提交状态（fail-closed）、成功包照常落位、
# 整轮以专用退出码 3 收场；全军覆没才是环境级失败（退出码 1）。这个测试在
# 临时 fixture 仓库里同时布置三类包，把三种结局都钉住。
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/sync-aur-packages.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

failures=0
ok() { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

fixture_pkgbuild() { # <name> <pkgver> [extra lines...]
    local name="$1" ver="$2"
    shift 2
    printf 'pkgname=%s\npkgver=%s\npkgrel=1\npkgdesc="sync fixture"\narch=(\x27any\x27)\nlicense=(\x27MIT\x27)\n' "$name" "$ver"
    printf '%s\n' "$@"
}

make_aur_repo() { # <name> <pkgver> [extra lines...]  → 路径
    local name="$1"
    shift
    local dir="$tmp/aur/$name"
    mkdir -p "$dir"
    fixture_pkgbuild "$name" "$@" | while IFS= read -r line; do printf '%s\n' "$line"; done > "$dir/PKGBUILD"
    git -C "$dir" init -q
    git -C "$dir" add PKGBUILD
    git -C "$dir" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm "aur $name"
    printf '%s\n' "$dir"
}

# 仓库骨架：真实脚本 + 三个包（good-pkg 正常前进；bad-pkg 的 overlay 必败；
# check-fail-pkg 引用不存在的本地 source，落位后才被 check-package 拦下）。
repo="$tmp/repo"
mkdir -p "$repo/scripts/overlays" "$repo/packages"
cp "$root/scripts/check-package.sh" "$root/scripts/validate-source-cache.sh" \
    "$root/scripts/pkgrel-floor.sh" "$repo/scripts/"
printf '#!/usr/bin/env bash\necho "intentional overlay failure for tests" >&2\nexit 1\n' \
    > "$repo/scripts/overlays/bad-pkg.sh"

aur_good="$(make_aur_repo good-pkg 1.1)"
aur_bad="$(make_aur_repo bad-pkg 1.0)"
aur_check="$(make_aur_repo check-fail-pkg 1.1 'source=("missing.patch")')"

init_package() { # <name> <pkgver> <aur-dir>
    local dir="$repo/packages/$1"
    mkdir -p "$dir"
    fixture_pkgbuild "$1" "$2" > "$dir/PKGBUILD"
    printf '%s\n' "$3" > "$dir/.aur-url"
    # 与真实仓库一致：.aur-commit 是已跟踪文件（还原路径依赖这一点）。
    printf '%s\n' '0000000000000000000000000000000000000000' > "$dir/.aur-commit"
    (cd "$dir" && makepkg --printsrcinfo > .SRCINFO)
}

init_package good-pkg 1.0 "$aur_good"
init_package bad-pkg 1.0 "$aur_bad"
init_package check-fail-pkg 1.0 "$aur_check"

git -C "$repo" init -q
git -C "$repo" add packages scripts
git -C "$repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm baseline

# 1. 混合结局：退出码 3，good 前进，bad 与 check-fail 保持已提交状态。
sync_failures="$tmp/sync-failures.tsv"
if REPO_ROOT="$repo" SYNC_FAILURES_FILE="$sync_failures" \
    bash "$script" > "$tmp/log" 2>&1; then
    fail 'expected exit 3 for a mixed sync outcome'
else
    rc=$?
    [[ "$rc" == 3 ]] \
        && ok 'a mixed sync run exits 3 (partial failure)' \
        || fail "expected exit 3, got $rc"
fi

[[ "$(awk -F= '/^pkgver=/{print $2; exit}' "$repo/packages/good-pkg/PKGBUILD")" == 1.1 ]] \
    && ok 'the healthy package still moved forward to 1.1' \
    || fail 'the healthy package did not advance'
[[ "$(awk -F= '/^pkgver=/{print $2; exit}' "$repo/packages/bad-pkg/PKGBUILD")" == 1.0 ]] \
    && ok 'the package with the failing overlay stayed at its committed state' \
    || fail 'the failing-overlay package was mutated'
[[ "$(awk -F= '/^pkgver=/{print $2; exit}' "$repo/packages/check-fail-pkg/PKGBUILD")" == 1.0 ]] \
    && ok 'the package rejected by check-package was restored to HEAD' \
    || fail 'the check-failed package was not restored'
[[ -z "$(git -C "$repo" status --porcelain -- packages/bad-pkg packages/check-fail-pkg)" ]] \
    && ok 'failed packages left no working-tree drift' \
    || fail 'failed packages left working-tree drift'
grep -q '^bad-pkg	' "$sync_failures" \
    && grep -q '^check-fail-pkg	check-package:' "$sync_failures" \
    && ok 'the failure manifest names both failed packages with reasons' \
    || fail "unexpected failure manifest: $(cat "$sync_failures")"
grep -q 'AUR sync failures (2 of 3 packages)' "$tmp/log" \
    && ok 'the summary counts isolated failures against the selection' \
    || fail 'missing per-package failure summary'

# 2. 全部失败 = 环境级失败：退出码 1，而不是 3。
rm -rf "$repo"
repo="$tmp/repo-all-fail"
mkdir -p "$repo/scripts/overlays" "$repo/packages"
cp "$root/scripts/check-package.sh" "$root/scripts/validate-source-cache.sh" \
    "$root/scripts/pkgrel-floor.sh" "$repo/scripts/"
printf '#!/usr/bin/env bash\nexit 1\n' > "$repo/scripts/overlays/solo-pkg.sh"
aur_solo="$(make_aur_repo solo-pkg 1.0)"
mkdir -p "$repo/packages/solo-pkg"
fixture_pkgbuild solo-pkg 1.0 > "$repo/packages/solo-pkg/PKGBUILD"
printf '%s\n' "$aur_solo" > "$repo/packages/solo-pkg/.aur-url"
(cd "$repo/packages/solo-pkg" && makepkg --printsrcinfo > .SRCINFO)
git -C "$repo" init -q
git -C "$repo" add packages scripts
git -C "$repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm baseline

if REPO_ROOT="$repo" bash "$script" > "$tmp/log2" 2>&1; then
    fail 'expected exit 1 when every selected package fails'
else
    rc=$?
    [[ "$rc" == 1 ]] \
        && ok 'an all-packages-failed run is an environment failure (exit 1)' \
        || fail "expected exit 1, got $rc"
fi
grep -q 'treating this as an environment failure' "$tmp/log2" \
    && ok 'the all-failed outcome says so explicitly' \
    || fail 'missing environment-failure explanation'

# 3. 全部成功：退出码 0。
rm -rf "$repo"
repo="$tmp/repo-all-good"
mkdir -p "$repo/scripts/overlays" "$repo/packages"
cp "$root/scripts/check-package.sh" "$root/scripts/validate-source-cache.sh" \
    "$root/scripts/pkgrel-floor.sh" "$repo/scripts/"
aur_good2="$(make_aur_repo plain-pkg 1.1)"
mkdir -p "$repo/packages/plain-pkg"
fixture_pkgbuild plain-pkg 1.0 > "$repo/packages/plain-pkg/PKGBUILD"
printf '%s\n' "$aur_good2" > "$repo/packages/plain-pkg/.aur-url"
(cd "$repo/packages/plain-pkg" && makepkg --printsrcinfo > .SRCINFO)
git -C "$repo" init -q
git -C "$repo" add packages scripts
git -C "$repo" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm baseline

if REPO_ROOT="$repo" bash "$script" > "$tmp/log3" 2>&1; then
    rc=0
else
    rc=$?
fi
[[ "$rc" == 0 ]] \
    && ok 'an all-success run still exits 0' \
    || fail "expected exit 0, got $rc"
[[ "$(awk -F= '/^pkgver=/{print $2; exit}' "$repo/packages/plain-pkg/PKGBUILD")" == 1.1 ]] \
    && ok 'the all-success run moved the package forward' \
    || fail 'the all-success run did not sync the package'

# 4. 用法错误仍是立即退出，不参与隔离。
if REPO_ROOT="$repo" bash "$script" nonexistent-pkg > /dev/null 2>&1; then
    fail 'expected a non-AUR package argument to fail'
else
    ok 'a non-AUR package argument is rejected outright (exit 1, not isolation)'
fi

if (( failures > 0 )); then
    printf '%d failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'all sync-aur-packages isolation cases passed\n'
