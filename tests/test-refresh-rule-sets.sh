#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
fixture="$work/repo"
mkdir -p "$fixture/scripts" "$fixture/packages/sing-box-rule-sets" "$work/bin"
cp "$root/scripts/refresh-rule-sets.sh" "$fixture/scripts/"
cp "$root/packages/sing-box-rule-sets/PKGBUILD" "$root/packages/sing-box-rule-sets/.SRCINFO" \
   "$root/packages/sing-box-rule-sets/must-direct.json" "$root/packages/sing-box-rule-sets/ads-extra.json" \
   "$root/packages/sing-box-rule-sets/LICENSE-anti-AD" "$fixture/packages/sing-box-rule-sets/"
sed -i 's/^pkgrel=.*/pkgrel=1/' "$fixture/packages/sing-box-rule-sets/PKGBUILD"
sed -i $'s/^\tpkgrel = .*/\tpkgrel = 1/' "$fixture/packages/sing-box-rule-sets/.SRCINFO"
# refresh 的版本规则是「上游变更落在同一天 → pkgrel+1；跨天 → pkgver 换当天、
# pkgrel 重置 1」。fixture 必须把 pkgver 钉到运行当天，否则树里的 pkgver 被
# 自动化推进到新的一天后（rule-sets 现在每 2 小时刷新一次），断言的 pkgrel
# 1→2 就永远不会发生——10-12 之后每次跑这条测试都因此失败。
fixture_date="$(date -u +%Y%m%d)"
sed -i "s/^pkgver=.*/pkgver=${fixture_date}/" "$fixture/packages/sing-box-rule-sets/PKGBUILD"
sed -i $'s/^\tpkgver = .*/\tpkgver = '"${fixture_date}"'/' "$fixture/packages/sing-box-rule-sets/.SRCINFO"
: > "$fixture/packages/sing-box-rule-sets/.source-hashes"
cat > "$work/bin/curl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
out=""; url="${@: -1}"
while (( $# )); do
    if [[ "$1" == -o ]]; then out="$2"; shift 2; else shift; fi
done
[[ -n "$out" ]]
case "$url" in
    *adguard.txt) seq 1 10001 > "$out" ;;
    *.srs) printf 'SRS-test-payload:%s\n' "${url##*/}" > "$out" ;;
    *) printf 'unexpected URL: %s\n' "$url" >&2; exit 1 ;;
esac
MOCK
chmod +x "$work/bin/curl"
PATH="$work/bin:/usr/bin:/bin" bash "$fixture/scripts/refresh-rule-sets.sh" >/dev/null
# 校验策略：六个易变远程源必须是 SKIP（钉死会随上游更新过期、拖垮整轮发布），
# 仓库内自制的三个文件必须仍然是真实哈希。
mapfile -t pkg_sums < <(sed -n '/^sha256sums=(/,/^)/p' \
    "$fixture/packages/sing-box-rule-sets/PKGBUILD" | grep -o "'[^']*'" | tr -d "'")
(( ${#pkg_sums[@]} == 9 )) || { printf 'expected 9 checksums, got %s\n' "${#pkg_sums[@]}" >&2; exit 1; }
for i in 0 1 2 3 4 5; do
    [[ "${pkg_sums[$i]}" == SKIP ]] || {
        printf 'remote source %s must be SKIP, got %s\n' "$i" "${pkg_sums[$i]}" >&2; exit 1; }
done
for pair in "6:must-direct.json" "7:ads-extra.json" "8:LICENSE-anti-AD"; do
    idx="${pair%%:*}"; file="${pair#*:}"
    want="$(sha256sum "$fixture/packages/sing-box-rule-sets/$file" | cut -d' ' -f1)"
    [[ "${pkg_sums[$idx]}" == "$want" ]] || {
        printf 'local source %s must be pinned to %s, got %s\n' "$file" "$want" "${pkg_sums[$idx]}" >&2; exit 1; }
done
[[ "$(wc -l < "$fixture/packages/sing-box-rule-sets/.source-hashes" | tr -d ' ')" == 6 ]]
grep -qx 'pkgrel=2' "$fixture/packages/sing-box-rule-sets/PKGBUILD"
grep -qx $'\tpkgrel = 2' "$fixture/packages/sing-box-rule-sets/.SRCINFO"
[[ "$(grep -c '^[[:space:]]*sha256sums = ' "$fixture/packages/sing-box-rule-sets/.SRCINFO")" == 9 ]]
[[ "$(grep -c $'^\tsha256sums = SKIP' "$fixture/packages/sing-box-rule-sets/.SRCINFO")" == 6 ]]
first_hashes="$(sha256sum "$fixture/packages/sing-box-rule-sets/.source-hashes" "$fixture/packages/sing-box-rule-sets/PKGBUILD" "$fixture/packages/sing-box-rule-sets/.SRCINFO")"
PATH="$work/bin:/usr/bin:/bin" bash "$fixture/scripts/refresh-rule-sets.sh" >/dev/null
second_hashes="$(sha256sum "$fixture/packages/sing-box-rule-sets/.source-hashes" "$fixture/packages/sing-box-rule-sets/PKGBUILD" "$fixture/packages/sing-box-rule-sets/.SRCINFO")"
[[ "$first_hashes" == "$second_hashes" ]]
printf 'Rule-set checksum regression test passed.\n'
