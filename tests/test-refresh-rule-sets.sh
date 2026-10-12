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
if grep -q "'SKIP'" "$fixture/packages/sing-box-rule-sets/PKGBUILD"; then
    printf 'PKGBUILD still contains SKIP checksums.\n' >&2; exit 1
fi
[[ "$(wc -l < "$fixture/packages/sing-box-rule-sets/.source-hashes" | tr -d ' ')" == 6 ]]
grep -qx 'pkgrel=2' "$fixture/packages/sing-box-rule-sets/PKGBUILD"
grep -qx $'\tpkgrel = 2' "$fixture/packages/sing-box-rule-sets/.SRCINFO"
[[ "$(grep -c '^[[:space:]]*sha256sums = ' "$fixture/packages/sing-box-rule-sets/.SRCINFO")" == 9 ]]
first_hashes="$(sha256sum "$fixture/packages/sing-box-rule-sets/.source-hashes" "$fixture/packages/sing-box-rule-sets/PKGBUILD" "$fixture/packages/sing-box-rule-sets/.SRCINFO")"
PATH="$work/bin:/usr/bin:/bin" bash "$fixture/scripts/refresh-rule-sets.sh" >/dev/null
second_hashes="$(sha256sum "$fixture/packages/sing-box-rule-sets/.source-hashes" "$fixture/packages/sing-box-rule-sets/PKGBUILD" "$fixture/packages/sing-box-rule-sets/.SRCINFO")"
[[ "$first_hashes" == "$second_hashes" ]]
printf 'Rule-set checksum regression test passed.\n'
