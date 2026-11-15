#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
script="$root/scripts/prepare-build-source.sh"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/pkg"

# makepkg 的 stub：真实环境里这一步只用来重新生成 .SRCINFO，测试不碰打包环境。
cat > "$tmp/bin/makepkg" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
rel="$(awk -F= '/^pkgrel=/{v=$2; sub(/#.*/, "", v); gsub(/[[:space:]]/, "", v); print v; exit}' PKGBUILD)"
printf 'pkgbase = demo\n\tpkgver = 1.2\n\tpkgrel = %s\n' "$rel" > .SRCINFO
MOCK
chmod +x "$tmp/bin/makepkg"

run_bump() { # <pkgrel-line>
    printf 'pkgname=demo\npkgver=1.2\n%s\n' "$1" > "$tmp/pkg/PKGBUILD"
    (cd "$tmp/pkg" && PATH="$tmp/bin:$PATH" BUMP_PKGREL=true bash "$script" "$tmp/pkg")
}

output="$(run_bump 'pkgrel=5')"
grep -q 'bumped pkgrel 5 -> 6' <<<"$output"
grep -q '^pkgrel=6$' "$tmp/pkg/PKGBUILD"
grep -q 'pkgrel = 6' "$tmp/pkg/.SRCINFO"
echo 'ok: an integer pkgrel is bumped in PKGBUILD and .SRCINFO'

output="$(run_bump 'pkgrel=2.6')"
grep -q 'bumped pkgrel 2.6 -> 2.7' <<<"$output"
grep -q '^pkgrel=2.7$' "$tmp/pkg/PKGBUILD"
echo 'ok: a decimal pkgrel is bumped segment-wise'

# quirc 的 PKGBUILD 在 pkgrel 行尾带注释；ABI 重建必须照样能 bump，否则漂移
# 一发生就在第一步报 unsupported pkgrel。与 pkgrel-floor.sh 同一政策：递增只
# 替换数字，行尾注释原样保留（它是本地定制的文档）。
output="$(run_bump 'pkgrel=5  # emoeem overlay: quirc pkgrel bump')"
grep -q 'bumped pkgrel 5 -> 6' <<<"$output"
grep -q '^pkgrel=6  # emoeem overlay: quirc pkgrel bump$' "$tmp/pkg/PKGBUILD"
echo 'ok: a commented pkgrel line is bumped with the comment preserved'

if output="$(run_bump 'pkgrel=1.2.3' 2>&1)"; then
    echo 'expected an unsupported pkgrel shape to fail' >&2
    exit 1
fi
grep -q 'Cannot auto-bump unsupported pkgrel' <<<"$output"
[[ "$(grep -c '^pkgrel=' "$tmp/pkg/PKGBUILD")" == 1 ]]
echo 'ok: an unsupported pkgrel shape still fails loudly'

# Repack 包显式退出递增：.pkgrel-floor-skip 在场时 BUMP_PKGREL=true 也不许
# 碰 pkgrel（Phase 1 之前 ABI 重建入口不认这个标记，dsh-desktop-linux 曾被
# 抬档出假升级）。.SRCINFO 缺失时也不许被顺手生成。
printf 'pkgname=demo\npkgver=1.2\npkgrel=1\n' > "$tmp/pkg/PKGBUILD"
rm -f "$tmp/pkg/.SRCINFO"
touch "$tmp/pkg/.pkgrel-floor-skip"
output="$(cd "$tmp/pkg" && PATH="$tmp/bin:$PATH" BUMP_PKGREL=true bash "$script" "$tmp/pkg")"
grep -q 'opts out via .pkgrel-floor-skip; nothing to bump' <<<"$output"
grep -q '^pkgrel=1$' "$tmp/pkg/PKGBUILD"
[[ ! -f "$tmp/pkg/.SRCINFO" ]]
echo 'ok: a .pkgrel-floor-skip package is never bumped by BUMP_PKGREL=true'

# 缺失 / 空的 pkgrel 行属于格式异常：明确报错而不是静默当作 0。
printf 'pkgname=demo\npkgver=1.2\n' > "$tmp/pkg/PKGBUILD"
rm -f "$tmp/pkg/.pkgrel-floor-skip"
if output="$(cd "$tmp/pkg" && PATH="$tmp/bin:$PATH" BUMP_PKGREL=true bash "$script" "$tmp/pkg" 2>&1)"; then
    echo 'expected a missing pkgrel line to fail' >&2
    exit 1
fi
grep -q 'Cannot auto-bump unsupported pkgrel' <<<"$output"
[[ "$(grep -c '^pkgver=1.2$' "$tmp/pkg/PKGBUILD")" == 1 ]]
[[ ! -f "$tmp/pkg/.SRCINFO" ]]
echo 'ok: a missing pkgrel line fails loudly and leaves the tree untouched'

# .SRCINFO 在场时走 sed 路径：两个文件一起前进，且不必调用 makepkg。
printf 'pkgname=demo\npkgver=1.2\npkgrel=5\n' > "$tmp/pkg/PKGBUILD"
printf 'pkgbase = demo\n\tpkgver = 1.2\n\tpkgrel = 5\n' > "$tmp/pkg/.SRCINFO"
cat > "$tmp/bin/makepkg" <<'MOCK'
#!/usr/bin/env bash
printf 'makepkg must not run: .SRCINFO already exists\n' >&2
exit 77
MOCK
output="$(cd "$tmp/pkg" && PATH="$tmp/bin:$PATH" BUMP_PKGREL=true bash "$script" "$tmp/pkg")"
grep -q 'bumped pkgrel 5 -> 6' <<<"$output"
grep -q '^pkgrel=6$' "$tmp/pkg/PKGBUILD"
grep -qF "$(printf '\tpkgrel = 6')" "$tmp/pkg/.SRCINFO"
echo 'ok: an existing .SRCINFO is updated by line rewrite, without invoking makepkg'

# 失败不得留下半修改状态：.SRCINFO 不存在、makepkg 必败时，递增必须在落盘
# 之前失败，PKGBUILD 原样保留、不留下临时文件。
printf 'pkgname=demo\npkgver=1.2\npkgrel=5\n' > "$tmp/pkg/PKGBUILD"
rm -f "$tmp/pkg/.SRCINFO"
if output="$(cd "$tmp/pkg" && PATH="$tmp/bin:$PATH" BUMP_PKGREL=true bash "$script" "$tmp/pkg" 2>&1)"; then
    echo 'expected the bump to fail when makepkg cannot produce .SRCINFO' >&2
    exit 1
fi
grep -q '^pkgrel=5$' "$tmp/pkg/PKGBUILD"
[[ ! -f "$tmp/pkg/.SRCINFO" ]]
shopt -s nullglob
leftovers=("$tmp/pkg"/.*pkgrel-tmp.* "$tmp/pkg"/.pkgrel-gen.*)
shopt -u nullglob
(( ${#leftovers[@]} == 0 )) || { printf 'leftover temp files: %s\n' "${leftovers[*]}" >&2; exit 1; }
echo 'ok: a failed bump leaves PKGBUILD byte-identical with no temp files'

printf 'pkgname=demo\npkgver=1.2\npkgrel=5\n' > "$tmp/pkg/PKGBUILD"
rm -f "$tmp/pkg/.SRCINFO"
(cd "$tmp/pkg" && PATH="$tmp/bin:$PATH" bash "$script" "$tmp/pkg")
grep -q '^pkgrel=5$' "$tmp/pkg/PKGBUILD"
[[ ! -f "$tmp/pkg/.SRCINFO" ]]
echo 'ok: nothing is touched when BUMP_PKGREL is unset'
