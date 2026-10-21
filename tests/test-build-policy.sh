#!/usr/bin/env bash
# Regression cover for scripts/validate-build-policy.sh's repository-ordering gate.
#
# The bug this pins down: the gate demanded that [emoeem] be the first pacman
# repository whenever LOCAL_REPO_DIR was set, even when that directory was empty
# and configure-build-repo.sh had therefore never written an [emoeem] stanza at
# all. Every build of a package without private dependencies then died with
#
#     Repository order violation: expected emoeem first, got cachyos-v3
#
# (Track Filee releases run 39593696778), because filee-update.yml mounts an
# empty localrepo on purpose.
#
# Both scripts are exercised through a fake pacman-conf and a fake gcc, so this
# runs anywhere - no pacman, no CachyOS, no network.
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
policy="${root}/scripts/validate-build-policy.sh"
configure="${root}/scripts/configure-build-repo.sh"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

failures=0
fail() {
    printf 'FAIL: %s\n' "$*" >&2
    failures=$((failures + 1))
}
ok() { printf 'ok: %s\n' "$*"; }

mkdir -p "$work/bin"
cat > "$work/bin/pacman-conf" <<'FAKE'
#!/usr/bin/env bash
if [[ "${1:-}" != "--repo-list" ]]; then
    printf 'fake pacman-conf: unsupported arguments: %s\n' "$*" >&2
    exit 1
fi
# Repository names arrive space separated so a scenario reads as one literal.
printf '%s\n' ${FAKE_REPO_LIST:?FAKE_REPO_LIST is not set}
FAKE
cat > "$work/bin/gcc" <<'FAKE'
#!/usr/bin/env bash
exit 0
FAKE
chmod +x "$work/bin/pacman-conf" "$work/bin/gcc"

# run_policy <repo-list> [local-repo-dir]
run_policy() {
    local repo_list="$1"
    local local_repo_dir="${2-}"
    if [[ -n "$local_repo_dir" ]]; then
        PATH="$work/bin:$PATH" FAKE_REPO_LIST="$repo_list" \
            LOCAL_REPO_NAME=emoeem LOCAL_REPO_DIR="$local_repo_dir" \
            bash "$policy" > "$work/out" 2>&1
    else
        PATH="$work/bin:$PATH" FAKE_REPO_LIST="$repo_list" \
            LOCAL_REPO_NAME=emoeem \
            bash "$policy" > "$work/out" 2>&1
    fi
}

expect_status() {
    local want="$1" label="$2"
    local got=0
    run_policy "${3-}" "${4-}" || got=$?
    if [[ "$got" == "$want" ]]; then
        ok "$label (exit $got)"
    else
        fail "$label: expected exit $want, got $got; output: $(tr '\n' ' ' < "$work/out")"
    fi
}

# 1. No local repository configured at all: ordering is irrelevant.
expect_status 0 'absent local repo, emoeem not in pacman.conf' 'cachyos-v3 extra'

# 2. Empty mounted repository: the shape that broke filee-update.
mkdir -p "$work/empty-repo"
expect_status 0 'empty local repo mount is tolerated' 'cachyos-v3 extra' "$work/empty-repo"

# 3. Configured and first: the authoritative-private-repo contract holds.
expect_status 0 'emoeem first in pacman.conf' 'emoeem cachyos-v3' "$work/empty-repo"
expect_status 0 'emoeem first, no mount' 'emoeem cachyos-v3'

# 4. Configured but shadowed by a distribution repository: still refused.
expect_status 2 'emoeem not first is refused' 'cachyos-v3 emoeem' "$work/empty-repo"
expect_status 2 'emoeem not first is refused without a mount' 'cachyos-v3 emoeem'

# 5. A populated repository that failed to reach pacman.conf is refused, since
#    that is exactly when a distro package could shadow a private one.
mkdir -p "$work/populated-repo"
: > "$work/populated-repo/example-1.0-1-x86_64.pkg.tar.zst"
expect_status 2 'populated local repo missing from pacman.conf is refused' \
    'cachyos-v3' "$work/populated-repo"

if ! grep -q 'is empty; building without it' "$work/out"; then
    : # the previous case is the refused one; the message is asserted below
fi

# 6. Empty mount prints why it was skipped instead of failing silently.
run_policy 'cachyos-v3' "$work/empty-repo" || true
if grep -q 'is empty; building without it' "$work/out"; then
    ok 'empty mount is reported, not silently ignored'
else
    fail "empty mount should be reported; output: $(tr '\n' ' ' < "$work/out")"
fi

# 7. configure-build-repo.sh agrees with the gate: an empty directory writes no
#    [emoeem] stanza, which is what makes case 2 legitimate rather than a hole.
mkdir -p "$work/etc"
printf '%s\n' '[options]' 'HoldPkg = pacman glibc' '' '[cachyos-v3]' 'Server = file:///dev/null' \
    > "$work/pacman.conf"
if LOCAL_REPO_NAME=emoeem LOCAL_REPO_DIR="$work/empty-repo" \
    bash -c '
        set -Eeuo pipefail
        # configure-build-repo.sh edits the real /etc/pacman.conf; redirect the
        # two absolute paths it touches into the fixture instead of needing root.
        pacman_conf="$1"
        sed -e "s#/etc/pacman.conf#$pacman_conf#g" -e "s#/tmp/emo-repo.conf#$2#g" \
            "'"$configure"'" > "$3"
        bash "$3"
    ' _ "$work/pacman.conf" "$work/emo-repo.conf" "$work/configure.sh" 2> "$work/out"; then
    if grep -q '^\[emoeem\]' "$work/pacman.conf"; then
        fail 'empty repository must not add an [emoeem] stanza'
    else
        ok 'empty repository leaves pacman.conf untouched'
    fi
else
    # configure-build-repo.sh ends by running pacman-conf, which the fake one
    # answers from FAKE_REPO_LIST; a non-zero exit here is still informative.
    fail "configure-build-repo.sh failed on an empty repository: $(tr '\n' ' ' < "$work/out")"
fi

if (( failures > 0 )); then
    printf '%s failure(s)\n' "$failures" >&2
    exit 1
fi
printf 'all build-policy repository-order cases passed\n'
