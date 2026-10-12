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
# 一发生就在第一步报 unsupported pkgrel。
output="$(run_bump 'pkgrel=5  # emoeem overlay: quirc pkgrel bump')"
grep -q 'bumped pkgrel 5 -> 6' <<<"$output"
grep -q '^pkgrel=6$' "$tmp/pkg/PKGBUILD"
echo 'ok: a commented pkgrel line is bumped'

if output="$(run_bump 'pkgrel=1.2.3' 2>&1)"; then
    echo 'expected an unsupported pkgrel shape to fail' >&2
    exit 1
fi
grep -q 'Cannot auto-bump unsupported pkgrel' <<<"$output"
echo 'ok: an unsupported pkgrel shape still fails loudly'

printf 'pkgname=demo\npkgver=1.2\npkgrel=5\n' > "$tmp/pkg/PKGBUILD"
rm -f "$tmp/pkg/.SRCINFO"
(cd "$tmp/pkg" && PATH="$tmp/bin:$PATH" bash "$script" "$tmp/pkg")
grep -q '^pkgrel=5$' "$tmp/pkg/PKGBUILD"
[[ ! -f "$tmp/pkg/.SRCINFO" ]]
echo 'ok: nothing is touched when BUMP_PKGREL is unset'
