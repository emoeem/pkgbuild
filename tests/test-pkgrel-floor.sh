#!/usr/bin/env bash
# pkgrel-floor.sh 的判据。
#
# 背景（2026-10-21）：仓库发布过 ffmpeg-full 9.0.2-2.11 和 mpeghdec 4.0.1-2，
# 之后一次构建又发出 9.0.2-2.6 / 4.0.1-1。repo-add 不比较版本，照单覆盖，
# 于是装了 2.11 / 4.0.1-2 的机器从此收不到这两个包的任何更新（pacman 只按
# 版本号判断升级）。这个脚本是那条「版本只许前进」规则唯一的实现，所以两个
# 调用点（AUR 同步、构建前）的行为都在这里钉住。
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/pkgrel-floor.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

failures=0
ok() { printf 'ok: %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

make_package() { # <dir-name> <pkgver> <pkgrel> [extra PKGBUILD lines...]
    local name="$1" ver="$2" rel="$3"
    shift 3
    local dir="$tmp/packages/$name"
    mkdir -p "$dir"
    {
        printf 'pkgname=%s\npkgver=%s\npkgrel=%s\narch=(\x27x86_64\x27)\n' "$name" "$ver" "$rel"
        printf '%s\n' "$@"
    } > "$dir/PKGBUILD"
    printf 'pkgbase = %s\n\tpkgver = %s\n\tpkgrel = %s\n' "$name" "$ver" "$rel" > "$dir/.SRCINFO"
    printf '%s\n' "$dir"
}

make_repository() { # <name> <version...>
    local name="$1"
    shift
    local repo="$tmp/repo"
    mkdir -p "$repo"
    local version
    for version in "$@"; do
        : > "$repo/${name}-${version}-x86_64.pkg.tar.zst"
    done
    printf '%s\n' "$repo"
}

pkgrel_of() { awk -F= '/^pkgrel=/{v=$2; sub(/#.*/, "", v); gsub(/[[:space:]]/, "", v); print v; exit}' "$1/PKGBUILD"; }
srcinfo_rel_of() { awk -F ' = ' '$1 == "\tpkgrel" {print $2; exit}' "$1/.SRCINFO"; }

# 1. 已发布版本就是这个源码版本：必须抬高，否则发出去没人能升级。
dir="$(make_package stable-demo 1.0 1)"
repo="$(make_repository stable-demo 1.0-1)"
bash "$script" "$dir" --against-repository "$repo" > "$tmp/log" 2>&1
[[ "$(pkgrel_of "$dir")" == 2 ]] && [[ "$(srcinfo_rel_of "$dir")" == 2 ]] \
    && ok 'an unpublished bump raises pkgrel 1 -> 2 in PKGBUILD and .SRCINFO' \
    || fail "expected pkgrel 2, got $(pkgrel_of "$dir") / $(srcinfo_rel_of "$dir")"
grep -q 'bumps pkgrel 1 -> 2' "$tmp/log" \
    && ok 'the bump is logged with the published reference' \
    || fail 'missing bump log line'

# 2. 事故现场：已发布 2.11、源码停在 2.6。必须直接跳到 2.12，而不是 2.7
#    （2.7 仍然比客户端装着的 2.11 旧，等于继续静默吞更新）。
rm -rf "$tmp/packages/ffmpeg-full" "$tmp/repo"
dir="$(make_package ffmpeg-full 9.0.2 2.6)"
repo="$(make_repository ffmpeg-full 9.0.2-2.11)"
bash "$script" "$dir" --against-repository "$repo" > "$tmp/log" 2>&1
[[ "$(pkgrel_of "$dir")" == 2.12 ]] \
    && ok 'a stale pkgrel jumps above the published 2.11 instead of stepping to 2.7' \
    || fail "expected pkgrel 2.12, got $(pkgrel_of "$dir")"

# 3. 源码已经比仓库新：一个字都不动（幂等，重复构建不无限抬版本号）。
rm -rf "$tmp/packages/stable-demo" "$tmp/repo"
dir="$(make_package stable-demo 1.0 2.12)"
repo="$(make_repository stable-demo 1.0-2.11)"
bash "$script" "$dir" --against-repository "$repo" > /dev/null 2>&1
[[ "$(pkgrel_of "$dir")" == 2.12 ]] \
    && ok 'an already-forward pkgrel is left untouched' \
    || fail "pkgrel moved to $(pkgrel_of "$dir")"

# 4. 还没发布过：没有下限，不抬。
rm -rf "$tmp/packages/brand-new" "$tmp/repo"
dir="$(make_package brand-new 1.0 1)"
mkdir -p "$tmp/repo"
bash "$script" "$dir" --against-repository "$tmp/repo" > "$tmp/log" 2>&1
[[ "$(pkgrel_of "$dir")" == 1 ]] \
    && ok 'a never-published package keeps its pkgrel' \
    || fail "pkgrel moved to $(pkgrel_of "$dir")"

# 5. 仓库里的 pkgver 更新 = 上游回退，构建出来必然是降级：必须拒绝，而不是
#    乖乖造一个更旧的包交给 repo-add 覆盖。
rm -rf "$tmp/packages/stable-demo" "$tmp/repo"
dir="$(make_package stable-demo 1.0 1)"
repo="$(make_repository stable-demo 1.1-1)"
if bash "$script" "$dir" --against-repository "$repo" > "$tmp/log" 2>&1; then
    fail 'expected a newer published pkgver to be refused'
else
    grep -q 'refusing to build a downgrade' "$tmp/log" \
        && ok 'a published pkgver that is newer stops the build' \
        || fail 'refusal reason missing'
fi

# 6. 源码 pkgver 前进（正常升级）：版本自然更大，不动 pkgrel。
rm -rf "$tmp/packages/stable-demo" "$tmp/repo"
dir="$(make_package stable-demo 1.1 1)"
repo="$(make_repository stable-demo 1.0-9)"
bash "$script" "$dir" --against-repository "$repo" > "$tmp/log" 2>&1
[[ "$(pkgrel_of "$dir")" == 1 ]] \
    && ok 'a pkgver upgrade advances without touching pkgrel' \
    || fail "pkgrel moved to $(pkgrel_of "$dir")"

# 7. VCS 包：版本在 makepkg 里解析，构建前不可知，脚本不猜（发布闸门兜住）。
rm -rf "$tmp/packages/foo-git" "$tmp/repo"
dir="$(make_package foo-git r10.abc1234 1 'pkgver() { echo "r11.def5678"; }')"
repo="$(make_repository foo-git r10.abc1234-1)"
bash "$script" "$dir" --against-repository "$repo" > "$tmp/log" 2>&1
[[ "$(pkgrel_of "$dir")" == 1 ]] \
    && ok 'a VCS package is left to pkgver() resolution' \
    || fail "pkgrel moved to $(pkgrel_of "$dir")"

# 8. 带 epoch 的包：文件名里没有 epoch，方向交给 vercmp。
rm -rf "$tmp/packages/epoch-demo" "$tmp/repo"
dir="$(make_package epoch-demo 1.0 1 'epoch=2')"
repo="$(make_repository epoch-demo 1.0-1)"
bash "$script" "$dir" --against-repository "$repo" > /dev/null 2>&1
[[ "$(pkgrel_of "$dir")" == 1 ]] \
    && ok 'an epoch package is left to vercmp' \
    || fail "pkgrel moved to $(pkgrel_of "$dir")"

# 9. AUR 同步：上游 PKGBUILD 的 pkgrel 不得把本地的 2.11 拉回 2。
rm -rf "$tmp/packages/ffmpeg-full" "$tmp/aur"
dir="$(make_package ffmpeg-full 9.0.2 2)"
mkdir -p "$tmp/aur"
printf 'pkgname=ffmpeg-full\npkgver=9.0.2\npkgrel=2.11\n' > "$tmp/aur/PKGBUILD"
bash "$script" "$dir" --against-pkgbuild "$tmp/aur/PKGBUILD" > "$tmp/log" 2>&1
[[ "$(pkgrel_of "$dir")" == 2.11 ]] \
    && ok 'AUR sync keeps the local 2.11 instead of resetting to the upstream 2' \
    || fail "expected pkgrel 2.11, got $(pkgrel_of "$dir")"

# 10. 上游 pkgver 变了：真正的上游发布，pkgrel 从上游基线重新开始。
rm -rf "$tmp/packages/demo" "$tmp/aur"
mkdir -p "$tmp/aur"
dir="$(make_package demo 2.0 1)"
printf 'pkgname=demo\npkgver=1.0\npkgrel=9\n' > "$tmp/aur/PKGBUILD"
bash "$script" "$dir" --against-pkgbuild "$tmp/aur/PKGBUILD" > /dev/null 2>&1
[[ "$(pkgrel_of "$dir")" == 1 ]] \
    && ok 'a new upstream pkgver restarts the pkgrel baseline' \
    || fail "pkgrel moved to $(pkgrel_of "$dir")"

# 11. 上游把 pkgrel 抬到 3（同时改了 PKGBUILD）：3 > 2.11，保留上游的 3。
rm -rf "$tmp/packages/demo" "$tmp/aur"
mkdir -p "$tmp/aur"
dir="$(make_package demo 1.0 3)"
printf 'pkgname=demo\npkgver=1.0\npkgrel=2.11\n' > "$tmp/aur/PKGBUILD"
bash "$script" "$dir" --against-pkgbuild "$tmp/aur/PKGBUILD" > /dev/null 2>&1
[[ "$(pkgrel_of "$dir")" == 3 ]] \
    && ok 'an upstream pkgrel that is numerically newer wins' \
    || fail "pkgrel moved to $(pkgrel_of "$dir")"

# 12. 行尾注释必须保住（quirc 的 `pkgrel=5  # emoeem overlay: ...`）。
rm -rf "$tmp/packages/quirc" "$tmp/repo"
dir="$(make_package quirc 1.2 5)"
sed -i 's/^pkgrel=5$/pkgrel=5  # emoeem overlay: quirc pkgrel bump/' "$dir/PKGBUILD"
repo="$(make_repository quirc 1.2-5)"
bash "$script" "$dir" --against-repository "$repo" > /dev/null 2>&1
grep -q '^pkgrel=6  # emoeem overlay: quirc pkgrel bump$' "$dir/PKGBUILD" \
    && ok 'the trailing comment on the pkgrel line survives the rewrite' \
    || fail "pkgrel line is now: $(grep '^pkgrel=' "$dir/PKGBUILD")"

# 13. 参数与入口的失败路径。
if bash "$script" "$tmp/packages/quirc" --against-repository > /dev/null 2>&1; then
    fail 'expected a missing reference argument to fail'
else
    ok 'a missing reference argument is rejected'
fi
if bash "$script" "$tmp/does-not-exist" --against-repository "$tmp/repo" > /dev/null 2>&1; then
    fail 'expected a missing package directory to fail'
else
    ok 'a missing package directory is rejected'
fi
if bash "$script" "$tmp/packages/quirc" --against-nonsense "$tmp/repo" > /dev/null 2>&1; then
    fail 'expected an unknown mode to fail'
else
    ok 'an unknown mode is rejected'
fi

if (( failures > 0 )); then
    printf '%d failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'all pkgrel-floor cases passed\n'
