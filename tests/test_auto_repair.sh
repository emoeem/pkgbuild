#!/usr/bin/env bash
# Regression tests for the transactional auto-repair engine.
#
# Every case here guards a property that a broken repair loop would silently
# lose: the dry run must not touch a file, a blocked level must not touch a
# file, a failed validation must restore the exact original bytes, and the
# repair budget must stop the build -> fix -> build -> fix spiral.
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

make_fixture() {
    local fixture="$1"
    rm -rf "$fixture"
    mkdir -p "$fixture/packages/demo"
    cat >"$fixture/packages/demo/PKGBUILD" <<'EOF'
pkgname=demo
pkgver=1.0
pkgrel=1
pkgdesc="demo package"
arch=('x86_64')
license=('MIT')
source=()
sha256sums=()

package() {
  install -d "$pkgdir/usr/bin"
  printf 'x\n' >"$pkgdir/usr/bin/demo"
}
EOF
    # A deliberately stale .SRCINFO: pkgrel disagrees with the PKGBUILD.
    cat >"$fixture/packages/demo/.SRCINFO" <<'EOF'
pkgbase = demo
	pkgdesc = demo package
	pkgver = 1.0
	pkgrel = 9
	arch = x86_64
	license = MIT
	source = 

pkgname = demo
EOF
}

write_failure() {
    local path="$1" category="$2" rule="$3" level="$4"
    cat >"$path" <<EOF
{
  "schema": 1,
  "package": "demo",
  "category": "$category",
  "confidence": "high",
  "root_cause": "fixture failure",
  "auto_fix": {"level": "$level", "safe": false, "reason": "fixture"}
  ,"matched_rules": [{"id": "$rule", "category": "$category", "stage": "prepare", "confidence": "high"}]
}
EOF
}

printf '%s\n' '1/6: dry run reports the strategy without modifying the workspace'
fixture="$work/repo"
make_fixture "$fixture"
write_failure "$work/failure.json" PKGBuildError srcinfo-stale level1
before="$(sha256sum "$fixture/packages/demo/.SRCINFO" | awk '{print $1}')"
bash "$root/scripts/auto-repair.sh" --package demo --failure "$work/failure.json" \
    --root "$fixture" --json --out "$work/record.json" >/dev/null || fail 'dry run exited non-zero'
after="$(sha256sum "$fixture/packages/demo/.SRCINFO" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail 'dry run modified .SRCINFO'
grep -q '"status": "dry-run"' "$work/record.json" || fail 'dry run did not report status dry-run'

printf '%s\n' '2/6: a repair above AUTO_FIX_LEVEL is blocked instead of applied'
bash "$root/scripts/auto-repair.sh" --package demo --failure "$work/failure.json" \
    --root "$fixture" --level 0 --apply --json --out "$work/record.json" >/dev/null ||
    fail 'level-gated repair exited non-zero'
grep -q '"status": "blocked-by-level"' "$work/record.json" || fail 'level gate did not block the repair'
after="$(sha256sum "$fixture/packages/demo/.SRCINFO" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail 'blocked repair modified .SRCINFO'

printf '%s\n' '3/6: regeneration repair fixes a stale .SRCINFO in place'
bash "$root/scripts/auto-repair.sh" --package demo --failure "$work/failure.json" \
    --root "$fixture" --level 2 --apply --json --out "$work/record.json" >/dev/null ||
    fail 'regeneration repair exited non-zero'
grep -q '"status": "applied"' "$work/record.json" || fail 'regeneration repair was not applied'
grep -qE '^	pkgrel = 1$' "$fixture/packages/demo/.SRCINFO" || fail 'pkgrel was not regenerated'
grep -q '"validation": "pass"' "$work/record.json" || fail 'applied repair did not pass validation'
grep -q '"diff":' "$work/record.json" || fail 'applied repair recorded no diff'

printf '%s\n' '4/6: a fix whose validation fails is rolled back byte for byte'
make_fixture "$fixture"
before="$(sha256sum "$fixture/packages/demo/.SRCINFO" | awk '{print $1}')"
if bash "$root/scripts/auto-repair.sh" --package demo --failure "$work/failure.json" \
    --root "$fixture" --level 2 --apply --validate-cmd false \
    --json --out "$work/record.json" >/dev/null 2>&1; then
    fail 'a failed validation still reported success'
fi
after="$(sha256sum "$fixture/packages/demo/.SRCINFO" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail 'rollback did not restore the original .SRCINFO'
grep -q '"status": "rolled-back"' "$work/record.json" || fail 'rollback was not recorded'
grep -q '"rollback": "restored"' "$work/record.json" || fail 'rollback did not verify restoration'

printf '%s\n' '5/6: the repair budget stops further attempts'
make_fixture "$fixture"
bash "$root/scripts/auto-repair.sh" --package demo --failure "$work/failure.json" \
    --root "$fixture" --level 2 --apply --max-attempts 1 --attempts-used 1 \
    --json --out "$work/record.json" >/dev/null || fail 'budget check exited non-zero'
grep -q '"status": "budget-exhausted"' "$work/record.json" || fail 'budget was not enforced'

printf '%s\n' '6/6: an unknown failure is reported, never silently edited'
printf '%s\n' '6a: unknown category maps to report-only'
write_failure "$work/unknown.json" CompilerError unknown-rule none
bash "$root/scripts/auto-repair.sh" --package demo --failure "$work/unknown.json" \
    --root "$fixture" --level 4 --apply --json --out "$work/record.json" >/dev/null ||
    fail 'report-only path exited non-zero'
grep -q '"status": "report-only"' "$work/record.json" || fail 'unknown failure was not report-only'
printf '%s\n' '6b: a level 3 SONAME repair is refused when the level ceiling is 2'
write_failure "$work/soname.json" SONAMEError soname-missing level3
bash "$root/scripts/auto-repair.sh" --package demo --failure "$work/soname.json" \
    --root "$fixture" --level 2 --apply --json --out "$work/record.json" >/dev/null ||
    fail 'soname repair at level 2 exited non-zero'
grep -q '"status": "blocked-by-level"' "$work/record.json" ||
    fail 'level 3 SONAME repair was not blocked at AUTO_FIX_LEVEL=2'

printf '%s\n' 'All auto-repair tests passed.'
