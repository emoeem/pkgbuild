#!/usr/bin/env bash
# pkgrel 策略库（scripts/lib/pkgrel-policy.sh）的单元测试 + 多入口一致性。
#
# Phase 1（2026-11-15）把四个脚本各自的 pkgrel 解析/比较/递增实现收敛到共享
# 库，并让 .pkgrel-floor-skip 在所有递增入口生效。这份测试钉住三件事：
#
#   1. 库函数自身的形状与边界（小数分段、注释剥离、非法形状报错）；
#   2. 所有递增入口对同一 fixture 的行为一致：.pkgrel-floor-skip 在场时谁
#      都不许动 pkgrel（E1 pkgrel-floor --against-repository、E3
#      prepare-build-source BUMP_PKGREL=true、E4 auto-repair bump_pkgrel）；
#   3. 递增入口产出的版本能被校验入口（verify-publish-inputs.sh 的
#      bumped-pkgrel 放行规则）接受——入口之间不能互相否定。
#
# set -e 语义是库的隐含契约的一部分：pkgrel_policy_next 对非法形状返回 1，
# 调用方必须显式接住，测试同时验证这一点不会把 caller 带崩。
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
lib="$root/scripts/lib/pkgrel-policy.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# makepkg 的 stub：与 test_prepare_build_source.sh 同款，只重生成 .SRCINFO。
mkdir -p "$tmp/bin"
cat > "$tmp/bin/makepkg" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
rel="$(awk -F= '/^pkgrel=/{v=$2; sub(/#.*/, "", v); gsub(/[[:space:]]/, "", v); print v; exit}' PKGBUILD)"
printf 'pkgbase = demo\n\tpkgver = 1.2\n\tpkgrel = %s\n' "$rel" > .SRCINFO
MOCK
chmod +x "$tmp/bin/makepkg"

make_package() { # <name> <pkgrel-line>
    local dir="$tmp/pkg-$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    printf 'pkgname=%s\npkgver=1.2\n%s\n' "$1" "$2" > "$dir/PKGBUILD"
    printf '%s\n' "$dir"
}

# ---- 1. 库单元 -----------------------------------------------------------

printf '%s\n' '1: policy units (skip / parse / cmp / next / apply)'
# shellcheck source=../scripts/lib/pkgrel-policy.sh
source "$lib"

skip_dir="$(make_package skipdemo pkgrel=1)"
touch "$skip_dir/.pkgrel-floor-skip"
pkgrel_policy_skip "$skip_dir" &&
    ! pkgrel_policy_skip "$(make_package noskip pkgrel=1)" ||
    fail 'pkgrel_policy_skip misidentifies the marker'

[[ "$(pkgrel_policy_parse <(printf 'pkgrel=5  # emoeem overlay: quirc pkgrel bump\n'))" == 5 ]] ||
    fail 'pkgrel_policy_parse does not strip the trailing comment'
[[ -z "$(pkgrel_policy_parse <(printf 'pkgver=1\n'))" ]] ||
    fail 'pkgrel_policy_parse invents a value for a missing line'

[[ "$(pkgrel_policy_cmp 2.10 2.9)" == 1 ]] || fail '2.10 must be newer than 2.9'
[[ "$(pkgrel_policy_cmp 2.6 2.11)" == -1 ]] || fail '2.6 must be older than 2.11'
[[ "$(pkgrel_policy_cmp 3 3.0)" == 0 ]] || fail '3 and 3.0 are equal segment-wise'
pkgrel_policy_cmp 2a 2 >/dev/null 2>&1 && fail 'non-numeric segments must fail the compare'

[[ "$(pkgrel_policy_next 5)" == 6 ]] || fail 'integer bump'
[[ "$(pkgrel_policy_next 2.11)" == 2.12 ]] || fail 'decimal bump must keep segments'
pkgrel_policy_next 1.2.3 >/dev/null 2>&1 && fail 'three segments are unsupported'
pkgrel_policy_next "" >/dev/null 2>&1 && fail 'an empty pkgrel is unsupported'

make_package applydemo pkgrel=2.6 > "$tmp/apply.dir"
apply_dir="$(cat "$tmp/apply.dir")"
printf 'pkgbase = demo\n\tpkgver = 1.2\n\tpkgrel = 2.6\n' > "$apply_dir/.SRCINFO"
pkgrel_policy_apply "$apply_dir" 2.7 || fail 'apply failed on a well-formed pair'
grep -q '^pkgrel=2.7$' "$apply_dir/PKGBUILD" || fail 'apply did not update the PKGBUILD'
grep -qF "$(printf '\tpkgrel = 2.7')" "$apply_dir/.SRCINFO" ||
    fail 'apply did not update the .SRCINFO'
make_package applycomment pkgrel='5  # emoeem overlay: quirc pkgrel bump' > "$tmp/apply2.dir"
apply2_dir="$(cat "$tmp/apply2.dir")"
pkgrel_policy_apply "$apply2_dir" 6 || fail 'apply failed on a commented pkgrel'
grep -q '^pkgrel=6  # emoeem overlay: quirc pkgrel bump$' "$apply2_dir/PKGBUILD" ||
    fail 'apply destroyed the trailing comment'
echo 'ok: policy units behave per the documented contract'

# ---- 2. 跨入口：.pkgrel-floor-skip 在场时谁都不许递增 ---------------------

printf '%s\n' '2: every increment entry honors .pkgrel-floor-skip'
fixture="$(make_package repack pkgrel=1)"
touch "$fixture/.pkgrel-floor-skip"

# E3：ABI 重建入口（Phase 1 之前的缺口）。
e3="$(cd "$fixture" && PATH="$tmp/bin:$PATH" BUMP_PKGREL=true \
    bash "$root/scripts/prepare-build-source.sh" "$fixture")"
grep -q 'opts out via .pkgrel-floor-skip' <<<"$e3" &&
    grep -q '^pkgrel=1$' "$fixture/PKGBUILD" ||
    fail 'prepare-build-source bumped a skip package'

# E1/E2：pkgrel-floor 的两种对齐模式。
repo="$tmp/repo"
mkdir -p "$repo"
cp "$fixture/${fixture##*/}" "$repo/dsh-desktop-linux-1.2-1-x86_64.pkg.tar.zst" 2>/dev/null || {
    # 用一个字节内容的伪包文件即可：pkgrel-floor 只解析文件名取版本。
    printf 'x\n' > "$repo/dsh-desktop-linux-1.2-1-x86_64.pkg.tar.zst"
}
e2="$(pkgrel_policy_skip "$fixture" && bash "$root/scripts/pkgrel-floor.sh" \
    "$fixture" --against-repository "$repo")"
grep -q 'opts out via .pkgrel-floor-skip' <<<"$e2" &&
    grep -q '^pkgrel=1$' "$fixture/PKGBUILD" ||
    fail 'pkgrel-floor touched a skip package'

aur_ref="$(make_package repack-aur pkgrel=9)"
e1="$(bash "$root/scripts/pkgrel-floor.sh" "$fixture" --against-pkgbuild "$aur_ref/PKGBUILD")"
grep -q 'opts out via .pkgrel-floor-skip' <<<"$e1" &&
    grep -q '^pkgrel=1$' "$fixture/PKGBUILD" ||
    fail 'pkgrel-floor --against-pkgbuild touched a skip package'

# E4：auto-repair 的 bump_pkgrel 策略（SONAMEError）改判 report-only。
mkdir -p "$tmp/repair/packages/repack"
cp "$fixture/PKGBUILD" "$tmp/repair/packages/repack/PKGBUILD"
touch "$tmp/repair/packages/repack/.pkgrel-floor-skip"
cat > "$tmp/soname.json" <<'EOF'
{"schema":1,"package":"repack","category":"SONAMEError","confidence":"high","root_cause":"fixture","auto_fix":{"level":"3","safe":false,"reason":"fixture"},"matched_rules":[{"id":"soname-mismatch","category":"SONAMEError","stage":"prepare","confidence":"high"}]}
EOF
bash "$root/scripts/auto-repair.sh" --package repack --failure "$tmp/soname.json" \
    --root "$tmp/repair" --level 3 --apply --json --out "$tmp/repair.json" >/dev/null ||
    fail 'auto-repair exited non-zero for a skip package'
grep -q '"status": "report-only"' "$tmp/repair.json" &&
    grep -q '^pkgrel=1$' "$tmp/repair/packages/repack/PKGBUILD" ||
    fail 'auto-repair bumped a skip package'
echo 'ok: E1/E2/E3/E4 all refuse to increment when .pkgrel-floor-skip is present'

# ---- 3. 跨入口：没有标记时的行为一致且可互相衔接 ---------------------------

printf '%s\n' '3: entries agree when the marker is absent'
fixture="$(make_package srcpkg pkgrel=5)"
repo="$tmp/repo2"
mkdir -p "$repo"
printf 'x\n' > "$repo/srcpkg-1.2-5-x86_64.pkg.tar.zst"

# E3：ABI 重建入口 +1（构建副本语义）。
(cd "$fixture" && PATH="$tmp/bin:$PATH" BUMP_PKGREL=true \
    bash "$root/scripts/prepare-build-source.sh" "$fixture") >/dev/null
grep -q '^pkgrel=6$' "$fixture/PKGBUILD" || fail 'prepare-build-source did not bump'

# 校验入口：bumped-pkgrel 放行规则必须接受 E3 的产物版本（6 == 源 5 + 1）。
sed -i 's/^\tpkgrel = .*/\tpkgrel = 5/' "$fixture/.SRCINFO" 2>/dev/null ||
    printf 'pkgbase = srcpkg\n\tpkgver = 1.2\n\tpkgrel = 5\n' > "$fixture/.SRCINFO"
# verify-publish-inputs 需要 incoming/<name>/*.pkg.tar.zst 的形态与 bsdtar；
# 这里直接验证同一个放行规则的输入计算，用 lib 的函数代替完整闸门（闸门
# 自身已有 test_publish_inputs.sh 覆盖）。
source "$root/scripts/lib/pkgrel-policy.sh"
[[ "$(pkgrel_policy_next 5)" == 6 ]] || fail 'gate-side next disagrees with bump-side next'

# E5：回写方向 —— 产物 6 对源 5 是前进，允许回写；产物 5 对源 6 不是。
pkgrel_policy_at_most 6 5 && fail 'at_most says 6<=5' || true
pkgrel_policy_at_most 5 6 || fail 'at_most must accept 5<=6'
pkgrel_policy_at_most 2.10 2.9 && fail 'at_most says 2.10<=2.9' || true
echo 'ok: bump side and gate side agree on the same segment arithmetic'

printf 'all pkgrel-policy cases passed\n'
