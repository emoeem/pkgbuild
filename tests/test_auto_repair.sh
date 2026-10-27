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

printf '%s\n' '1/8: dry run reports the strategy without modifying the workspace'
fixture="$work/repo"
make_fixture "$fixture"
write_failure "$work/failure.json" PKGBuildError srcinfo-stale level1
before="$(sha256sum "$fixture/packages/demo/.SRCINFO" | awk '{print $1}')"
bash "$root/scripts/auto-repair.sh" --package demo --failure "$work/failure.json" \
    --root "$fixture" --json --out "$work/record.json" >/dev/null || fail 'dry run exited non-zero'
after="$(sha256sum "$fixture/packages/demo/.SRCINFO" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail 'dry run modified .SRCINFO'
grep -q '"status": "dry-run"' "$work/record.json" || fail 'dry run did not report status dry-run'

printf '%s\n' '2/8: a repair above AUTO_FIX_LEVEL is blocked instead of applied'
bash "$root/scripts/auto-repair.sh" --package demo --failure "$work/failure.json" \
    --root "$fixture" --level 0 --apply --json --out "$work/record.json" >/dev/null ||
    fail 'level-gated repair exited non-zero'
grep -q '"status": "blocked-by-level"' "$work/record.json" || fail 'level gate did not block the repair'
after="$(sha256sum "$fixture/packages/demo/.SRCINFO" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail 'blocked repair modified .SRCINFO'

printf '%s\n' '3/8: regeneration repair fixes a stale .SRCINFO in place'
bash "$root/scripts/auto-repair.sh" --package demo --failure "$work/failure.json" \
    --root "$fixture" --level 2 --apply --json --out "$work/record.json" >/dev/null ||
    fail 'regeneration repair exited non-zero'
grep -q '"status": "applied"' "$work/record.json" || fail 'regeneration repair was not applied'
grep -qE '^	pkgrel = 1$' "$fixture/packages/demo/.SRCINFO" || fail 'pkgrel was not regenerated'
grep -q '"validation": "pass"' "$work/record.json" || fail 'applied repair did not pass validation'
grep -q '"diff":' "$work/record.json" || fail 'applied repair recorded no diff'

printf '%s\n' '4/8: a fix whose validation fails is rolled back byte for byte'
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

printf '%s\n' '5/8: the repair budget stops further attempts'
make_fixture "$fixture"
bash "$root/scripts/auto-repair.sh" --package demo --failure "$work/failure.json" \
    --root "$fixture" --level 2 --apply --max-attempts 1 --attempts-used 1 \
    --json --out "$work/record.json" >/dev/null || fail 'budget check exited non-zero'
grep -q '"status": "budget-exhausted"' "$work/record.json" || fail 'budget was not enforced'

printf '%s\n' '6/8: an unknown failure is reported, never silently edited'
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

printf '%s\n' '7/8: a stale repository-managed pin is handed to its update workflow'
make_fixture "$fixture"
mkdir -p "$fixture/config"
cat >"$fixture/config/package-updates.txt" <<'EOF'
# <package> <kind> <target>
demo workflow .github/workflows/refresh-demo.yml
EOF
write_failure "$work/checksum.json" SourceError checksum-mismatch level2
mkdir -p "$work/bin"
cat >"$work/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"$MOCK_GH_LOG"
if [[ "${1:-}" == "run" && "${2:-}" == "list" ]]; then
    printf '%s\n' "${MOCK_GH_RUN_STATUS:-completed}"
    exit 0
fi
if [[ "${1:-}" == "workflow" && "${2:-}" == "run" ]]; then
    exit 0
fi
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
MOCK
chmod +x "$work/bin/gh"
export MOCK_GH_LOG="$work/gh.log" GITHUB_REPOSITORY="example/repo" GH_TOKEN="mock"
: >"$MOCK_GH_LOG"
before="$(sha256sum "$fixture/packages/demo/PKGBUILD" | awk '{print $1}')"
PATH="$work/bin:$PATH" bash "$root/scripts/auto-repair.sh" --package demo \
    --failure "$work/checksum.json" --root "$fixture" --level 1 --apply \
    --json --out "$work/record.json" >/dev/null || fail 'hand-off repair exited non-zero'
after="$(sha256sum "$fixture/packages/demo/PKGBUILD" | awk '{print $1}')"
[[ "$before" == "$after" ]] || fail 'hand-off repair modified the PKGBUILD'
grep -q '"status": "dispatched"' "$work/record.json" ||
    fail 'hand-off was not reported as dispatched'
grep -q '"strategy": "dispatch_refresh_workflow"' "$work/record.json" ||
    fail 'hand-off did not record the dispatch strategy'
grep -q '"validation": "not-needed"' "$work/record.json" ||
    fail 'hand-off claimed a workspace validation it never ran'
grep -q 'workflow run .github/workflows/refresh-demo.yml' "$MOCK_GH_LOG" ||
    fail 'the owning update workflow was not dispatched'

printf '%s\n' '8/8: an unowned or already-running source is never dispatched twice'
printf '%s\n' '8a: a repository-managed source with no registry entry stays report-only'
make_fixture "$fixture"
: >"$MOCK_GH_LOG"
bash "$root/scripts/auto-repair.sh" --package demo --failure "$work/checksum.json" \
    --root "$fixture" --level 1 --apply --json --out "$work/record.json" >/dev/null ||
    fail 'refusal path exited non-zero'
grep -q '"status": "report-only"' "$work/record.json" || fail 'unowned source was not report-only'
grep -q 'refusing to accept new upstream content automatically' "$work/record.json" ||
    fail 'the refusal reason changed'
if grep -q 'workflow run' "$MOCK_GH_LOG"; then
    fail 'a source without an owning workflow was dispatched'
fi
printf '%s\n' '8b: an in-flight refresh run suppresses a second dispatch'
make_fixture "$fixture"
mkdir -p "$fixture/config"
cat >"$fixture/config/package-updates.txt" <<'EOF'
demo workflow .github/workflows/refresh-demo.yml
EOF
: >"$MOCK_GH_LOG"
MOCK_GH_RUN_STATUS=in_progress PATH="$work/bin:$PATH" bash "$root/scripts/auto-repair.sh" \
    --package demo --failure "$work/checksum.json" --root "$fixture" --level 1 --apply \
    --json --out "$work/record.json" >/dev/null || fail 'in-flight guard exited non-zero'
grep -q '"status": "report-only"' "$work/record.json" ||
    fail 'an in-flight refresh run did not stop the dispatch'
grep -q 'already in flight' "$work/record.json" || fail 'the in-flight reason is missing'
if grep -q 'workflow run' "$MOCK_GH_LOG"; then
    fail 'a second refresh run was dispatched while one was in flight'
fi

printf '%s\n' '9: a stale source cache is cleared instead of re-pinning the checksums'
# `updpkgsums` on a stale cache would bake a hash of the stale bytes into the
# PKGBUILD: the build goes green and the repository now declares content it has
# never validated. The cache has to be ruled out before any re-pin is allowed.
stale_repo="$work/stale-repo"
make_fixture "$stale_repo"
printf 'https://aur.archlinux.org/demo.git\n' >"$stale_repo/packages/demo/.aur-url"
cat >"$stale_repo/packages/demo/.SRCINFO" <<'EOF'
pkgbase = demo
	source = fixture.patch::https://example.invalid/fixture.patch
	sha256sums = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
EOF
stale_cache="$work/stale-cache"
mkdir -p "$stale_cache/sources/demo"
printf 'stale bytes, not the empty-file digest\n' >"$stale_cache/sources/demo/fixture.patch"
write_failure "$work/stale-failure.json" SourceError checksum-mismatch level2
pkgbuild_before="$(sha256sum "$stale_repo/packages/demo/PKGBUILD" | awk '{print $1}')"
srcinfo_before="$(sha256sum "$stale_repo/packages/demo/.SRCINFO" | awk '{print $1}')"
CACHE_DIR="$stale_cache" bash "$root/scripts/auto-repair.sh" --package demo \
    --failure "$work/stale-failure.json" --root "$stale_repo" --level 2 --apply \
    --json --out "$work/stale-record.json" >/dev/null \
    || fail 'stale-cache repair exited non-zero'
grep -q '"strategy": "clear_stale_source_cache"' "$work/stale-record.json" \
    || fail 'auto-repair did not prefer clearing the stale cache over re-pinning'
grep -q '"status": "stale-cache-cleared"' "$work/stale-record.json" \
    || fail 'stale-cache repair did not report status stale-cache-cleared'
[[ ! -e "$stale_cache/sources/demo/fixture.patch" ]] || fail 'stale cached source survived the repair'
[[ "$pkgbuild_before" == "$(sha256sum "$stale_repo/packages/demo/PKGBUILD" | awk '{print $1}')" ]] \
    || fail 'the repair rewrote the PKGBUILD while only a cache entry was stale'
[[ "$srcinfo_before" == "$(sha256sum "$stale_repo/packages/demo/.SRCINFO" | awk '{print $1}')" ]] \
    || fail 'the repair rewrote .SRCINFO while only a cache entry was stale'

printf '%s\n' '10: a checksum mismatch with a clean cache still reaches the re-pin strategy'
: >"$stale_cache/sources/demo/fixture.patch"
CACHE_DIR="$stale_cache" bash "$root/scripts/auto-repair.sh" --package demo \
    --failure "$work/stale-failure.json" --root "$stale_repo" --level 1 --apply \
    --json --out "$work/clean-record.json" >/dev/null 2>&1 || true
grep -q '"strategy": "refresh_checksum"' "$work/clean-record.json" \
    || fail 'a clean cache did not fall through to the checksum-refresh strategy'
grep -q '"status": "blocked-by-level"' "$work/clean-record.json" \
    || fail 'the level gate did not block the checksum refresh at AUTO_FIX_LEVEL=1'

printf '%s\n' '11: a repair that could not run is reported instead of exiting silently'
grep -Fq 'Automatic repair did not run' "$root/.github/workflows/build.yml" \
    || fail 'build.yml does not report blocked repairs'
grep -Fq 'gh issue comment' "$root/.github/workflows/build.yml" \
    || fail 'a blocked repair is not recorded on the build-failure issue'
grep -Fq 'CACHE_DIR: ${{ github.workspace }}/.cache/pkgbuild' "$root/.github/workflows/build.yml" \
    || fail 'the repair step does not point CACHE_DIR at the host source cache'

printf '%s\n' '12: a report-only run never deletes the stale cache entry'
# The staleness verdict is established by deleting the stale file, so a run that
# is not allowed to write must not even ask the question.
printf 'stale bytes again\n' >"$stale_cache/sources/demo/fixture.patch"
CACHE_DIR="$stale_cache" bash "$root/scripts/auto-repair.sh" --package demo \
    --failure "$work/stale-failure.json" --root "$stale_repo" --level 0 --apply \
    --json --out "$work/level0-record.json" >/dev/null 2>&1 || true
[[ -f "$stale_cache/sources/demo/fixture.patch" ]] \
    || fail 'a level 0 (report-only) run deleted a cache entry'
grep -q '"status": "blocked-by-level"' "$work/level0-record.json" \
    || fail 'a level 0 run reported something other than blocked-by-level'
grep -q '"strategy": "refresh_checksum"' "$work/level0-record.json" \
    || fail 'a level 0 run did not fall through to the re-pin strategy it must refuse'

printf '%s\n' 'All auto-repair tests passed.'
