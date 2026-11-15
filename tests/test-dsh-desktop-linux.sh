#!/usr/bin/env bash
# dsh-desktop-linux（binary repack）的打包一致性测试（Phase 2）。
#
# 这个包的 depends=() 声明是人工维护的，而自动更新器只 pin pkgver/sha256：
# 上游 0.2.2rc2 删掉冗余的 libxss 后，本地声明漂移了三个版本才被发现
# （reports/pkgbuild-optimization/dsh-audit.md §1/§2）。build() 现在把资产
# .PKGINFO 的 depend 集合与本地数组做双向对账，这份测试钉住三件事：
#
#   1. PKGBUILD 与 .SRCINFO 的 depends 集合一致，且 libxss 不再出现；
#   2. build() 的对账在两个方向都会响亮失败（本地多余、资产多余），
#      而对集合一致的资产放行——用合成资产跑，不联网；
#   3. 打包外围自洽：AppArmor optdepends 与 install 脚本的 profile 路径
#      对得上，.desktop 断言已登记进 smoke-tests.yaml。
#
# depends/pkgname/pkgver/_asset 都由下面 source 的 PKGBUILD 带入；ShellCheck
# 无法跟踪动态路径的赋值，SC2154 在此文件全部豁免。
# shellcheck disable=SC2154
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
pkg="$root/packages/dsh-desktop-linux"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

# ---- 1. 元数据一致性 ------------------------------------------------------

printf '%s\n' '1: depends metadata agrees across PKGBUILD and .SRCINFO, no libxss'
grep -qE "^depends=\(" "$pkg/PKGBUILD" || fail 'PKGBUILD has no depends array'
grep -qE "^[[:space:]]*'libxss'" "$pkg/PKGBUILD" &&
    fail 'the dropped upstream libxss is still declared in PKGBUILD'
grep -qE '^	depends = libxss$' "$pkg/.SRCINFO" &&
    fail 'the dropped upstream libxss is still declared in .SRCINFO'

export CARCH=x86_64
# shellcheck source=../packages/dsh-desktop-linux/PKGBUILD
source "$pkg/PKGBUILD"
(( ${#depends[@]} > 0 )) || fail 'depends array did not load'

declare -A srcinfo_depends=()
while IFS= read -r line; do
    srcinfo_depends["$line"]=1
done < <(awk -F ' = ' '$1 == "\tdepends" {print $2}' "$pkg/.SRCINFO")
for declared in "${depends[@]}"; do
    [[ -n "${srcinfo_depends[$declared]:-}" ]] ||
        fail "PKGBUILD depends on $declared but .SRCINFO does not"
    unset "srcinfo_depends[$declared]"
done
(( ${#srcinfo_depends[@]} == 0 )) ||
    fail ".SRCINFO declares depends the PKGBUILD does not: ${!srcinfo_depends[*]}"
echo "ok: ${#depends[@]} depends agree in PKGBUILD and .SRCINFO (no libxss)"

# ---- 2. build() 的依赖对账 ------------------------------------------------

printf '%s\n' '2: build() reconciles the asset depends in both directions'
# 合成资产：zstd tar 只含 .PKGINFO，字段满足 build() 前置的 pkgname/pkgver/arch
# 校验（真实资产写的是 `arch = x86_64`，与 makepkg 7.1.0 一致；另有上游的
# makedepend = nodejs/pnpm/python，字段名不同，不进入 depend 对账）。
make_asset() { # <srcdir> <depends...>
    local dir="$1" info="$1/.PKGINFO" depend
    mkdir -p "$dir"
    {
        printf 'pkgname = %s\n' "$pkgname"
        printf 'pkgbase = %s\n' "$pkgname"
        printf 'pkgver = %s-1\n' "$pkgver"
        printf 'arch = %s\n' "$CARCH"
        for depend in "${@:2}"; do
            printf 'depend = %s\n' "$depend"
        done
    } > "$info"
    bsdtar --zstd -cf "$dir/${_asset}" -C "$dir" .PKGINFO
    rm -f "$info"
}

srcdir="$tmp/asset-ok"
make_asset "$srcdir" "${depends[@]}"
build || fail 'build() rejected an asset whose depends match this PKGBUILD'
echo 'ok: a matching asset passes the reconciliation'

srcdir="$tmp/asset-extra"
make_asset "$srcdir" "${depends[@]}" 'fakenewlib'
if err="$(build 2>&1)"; then
    fail 'build() accepted an asset with a dependency this PKGBUILD does not declare'
fi
grep -q 'declares dependencies this PKGBUILD does not: fakenewlib' <<<"$err" ||
    fail "the extra-dependency error does not name the offender: $err"
echo 'ok: an asset-only dependency fails loudly and names it'

srcdir="$tmp/asset-missing"
mapfile -t reduced < <(printf '%s\n' "${depends[@]}" | grep -vx 'libdbusmenu-glib')
make_asset "$srcdir" "${reduced[@]}"
if err="$(build 2>&1)"; then
    fail 'build() accepted an asset missing a locally declared dependency'
fi
grep -q 'this PKGBUILD depends on libdbusmenu-glib, but the upstream asset does not declare it' \
    <<<"$err" || fail "the missing-dependency error does not name the offender: $err"
echo 'ok: a locally declared dependency absent from the asset fails loudly and names it'

# ---- 3. 打包外围自洽 ------------------------------------------------------

printf '%s\n' '3: packaging periphery is self-consistent'
grep -q '^optdepends=.*apparmor' "$pkg/PKGBUILD" || fail 'apparmor optdepends is missing'
grep -q '/etc/apparmor.d/deepseek-harness' "$pkg/dsh-desktop-linux.install" ||
    fail 'the install script does not reference the bundled AppArmor profile path'
grep -q '/usr/share/applications/deepseek-harness.desktop' \
    "$root/scripts/data/smoke-tests.yaml" ||
    fail 'the .desktop assertion is not registered in smoke-tests.yaml'
echo 'ok: apparmor optdepends, install script and smoke assertions line up'

printf 'all dsh-desktop-linux cases passed\n'
