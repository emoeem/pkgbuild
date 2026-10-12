#!/usr/bin/env bash
# Remove the orphaned local-snapshot client: ./scripts/remove-legacy-repo-update.sh
#
# 11d8cde ("publish: switch to rolling GitHub Release pacman repository") deleted
# the installer for `emoeem-update` and its six-hourly `emoeem-repo-update.timer`:
# the repository is consumed straight from the rolling Release over HTTPS now
# (pacman.conf Server = .../releases/download/repo). Machines that had installed
# the old client keep the units, and because /var/lib/emoeem-repo no longer exists
# they fail with `Git repository not found: /var/lib/emoeem-repo` four times a day.
# The permanent failed unit then hides real boot problems from `systemctl --failed`
# and makes the state look broken.
#
# This script only removes those leftovers. /etc/pacman.conf, the [emoeem]
# section, the installed packages and everything else are left untouched.
#
# Usage: sudo scripts/remove-legacy-repo-update.sh --apply
#        scripts/remove-legacy-repo-update.sh            # dry run (default)
set -Eeuo pipefail

export LC_ALL=C

apply=0
while (( $# > 0 )); do
    case "$1" in
        --apply) apply=1 ;;
        --dry-run) apply=0 ;;
        --help | -h) sed -n '2,17p' "${BASH_SOURCE[0]}"; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
    shift
done

readonly legacy_service=/etc/systemd/system/emoeem-repo-update.service
readonly expected_exec=/usr/local/bin/emoeem-update
readonly legacy_paths=(
    /etc/systemd/system/emoeem-repo-update.timer
    /etc/systemd/system/emoeem-repo-update.service
    /usr/local/bin/emoeem-update
    /etc/emoeem-repo.conf
)

present=()
for path in "${legacy_paths[@]}"; do
    if [[ -e "$path" ]]; then
        present+=("$path")
    fi
done

if (( ${#present[@]} == 0 )); then
    printf 'Nothing to do: no legacy emoeem-repo-update artifact is installed.\n'
    exit 0
fi

# Guard against deleting a unit that has been repurposed for something else: the
# legacy service is identifiable by this exact ExecStart line and nothing more.
if [[ -e "$legacy_service" ]] && ! grep -qF -- "$expected_exec" "$legacy_service"; then
    printf '%s no longer points at %s;\nrefusing to remove a unit that was repurposed.\n' \
        "$legacy_service" "$expected_exec" >&2
    exit 1
fi

printf 'Legacy emoeem-repo-update artifacts found:\n'
printf '  %s\n' "${present[@]}"
printf '\n'

if (( apply == 1 )) && (( EUID != 0 )); then
    printf 'Removing system units and root-owned files needs root; re-run with sudo.\n' >&2
    exit 1
fi

run() {
    if (( apply == 1 )); then
        printf '+ %s\n' "$*"
        "$@"
    else
        printf '  would run: %s\n' "$*"
    fi
}

# Stop the timer first: otherwise it can fire between the rm and daemon-reload.
run systemctl disable --now emoeem-repo-update.timer || true
run systemctl stop emoeem-repo-update.service || true
run rm -f -- "${present[@]}"
run systemctl daemon-reload
# The failed unit stays in memory until it is reset, and `systemctl --failed`
# keeps showing it even after the files are gone.
run systemctl reset-failed emoeem-repo-update.service || true
if (( apply == 0 )); then
    (( EUID == 0 )) || printf '\n(dry run: the systemd queries below are skipped without root)\n'
fi

if (( apply == 0 )); then
    printf '\nDry run only. Re-run with --apply (as root) to remove these files.\n'
    exit 0
fi

# --- verification -----------------------------------------------------------
printf '\nVerification\n'
leftovers=()
for path in "${legacy_paths[@]}"; do
    if [[ -e "$path" ]]; then
        leftovers+=("$path")
    fi
done
if (( ${#leftovers[@]} > 0 )); then
    printf 'FAIL still present: %s\n' "${leftovers[*]}" >&2
    exit 1
fi
printf 'PASS no legacy artifact remains\n'

if [[ -n "$(systemctl list-unit-files 'emoeem*' --no-legend 2>/dev/null)" ]]; then
    printf 'FAIL systemd still knows an emoeem* unit:\n' >&2
    systemctl list-unit-files 'emoeem*' --no-legend >&2
    exit 1
fi
printf 'PASS systemd no longer knows any emoeem* unit\n'

if systemctl --failed --no-legend 2>/dev/null | grep -q 'emoeem-repo-update'; then
    printf 'FAIL the failed unit is still listed by systemctl --failed\n' >&2
    exit 1
fi
printf 'PASS nothing named emoeem-repo-update is in systemctl --failed\n'

printf '\nPackages themselves are untouched: [emoeem] is fetched from the rolling\n'
printf 'GitHub Release, so `pacman -Syu` keeps working exactly as before.\n'
