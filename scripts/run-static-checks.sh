#!/usr/bin/env bash
# The static half of CI, as one entry point.
#
# `check.yml` runs this script on the bare runner, and `.githooks/pre-commit`
# runs the same script on a developer machine, so "green locally" and "green in
# the integration job" mean the same thing by construction: there is only one
# list of checks.  Adding a check means adding it here (and the test that guards
# this file fails when the list changes without that).
#
# Everything below needs no container, no makepkg and no network: roughly ten
# seconds on a laptop, which is what makes it usable as a commit hook.  The
# checks that do need a container (`.SRCINFO` freshness, full package audit,
# real `repo-add` integration) still run in the `check` and `integration` jobs
# of `check.yml`, after this one has already rejected the cheap mistakes.
#
# Usage:
#
#   scripts/run-static-checks.sh                # run every check
#   scripts/run-static-checks.sh --list         # print check names, one per line
#   scripts/run-static-checks.sh --only shellcheck,python-syntax
#
# Environment:
#
#   EMO_SKIP_STATIC_CHECKS=1   the git hook skips the suite (see .githooks)
#
# Exit status is 0 when every check passed and 1 when any check failed.  All
# checks run even after a failure, so one commit reports every problem it has.

set -Eeuo pipefail

# Resolved with shell builtins only (no dirname): a PATH that has lost its
# coreutils must not be able to turn this gate into a no-op.
script_path="${BASH_SOURCE[0]}"
script_dir="${script_path%/*}"
[[ "$script_dir" == "$script_path" ]] && script_dir="."
root="$(cd -- "${script_dir}/.." && pwd)"
cd "$root"

# Order matters only for speed: the manifest gate is pure Python and rejects
# broken package metadata before anything compiles a fixture or shells out.
checks=(
    "package-manifest-policy"
    "package-manifest-tests"
    "select-packages"
    "elf-soname"
    "rebuild-triggers"
    "workflow-images"
    "aur-dependency-fallback"
    "build-regressions"
    "shell-syntax"
    "shellcheck"
    "python-syntax"
)

require_tool() {
    if ! command -v "$1" > /dev/null 2>&1; then
        printf 'ERROR: %s is not installed; install it or run this entry in the builder image\n' "$1" >&2
        return 1
    fi
}

run_check() {
    case "$1" in
        package-manifest-policy)
            # Same command as the check.yml step, and the reason it runs first:
            # a package with no update source fails in seconds on the bare
            # runner instead of minutes into a container job.
            python3 scripts/check-package-manifests.py
            ;;
        package-manifest-tests)
            python3 tests/test_package_manifests.py
            ;;
        select-packages)
            python3 tests/test_select_packages.py
            ;;
        elf-soname)
            bash tests/test_elf_soname.sh
            ;;
        rebuild-triggers)
            # packages/*/.rebuild-on is load bearing twice over (soname
            # exemptions and dependency-drift triggers), so its parser and the
            # ELF modes that consume it are covered here.
            bash tests/test-rebuild-on-triggers.sh
            ;;
        workflow-images)
            python3 tests/test_workflow_images.py
            ;;
        aur-dependency-fallback)
            bash tests/test-aur-dependency-fallback.sh
            ;;
        build-regressions)
            # Static grep/assert regressions for past build breaks. It used to
            # be listed in the README and run by nobody; it is cheap, needs no
            # container, and belongs in the gate that actually runs.
            bash tests/test-build-regressions.sh
            ;;
        shell-syntax)
            bash -n manage.sh scripts/*.sh client/*.sh tests/*.sh
            ;;
        shellcheck)
            require_tool shellcheck || return 1
            # --severity=warning matches the per-package CI step; a lower
            # severity would turn style opinions into a blocked commit.
            shellcheck --severity=warning manage.sh scripts/*.sh client/*.sh tests/*.sh
            ;;
        python-syntax)
            require_tool python3 || return 1
            PYTHONPYCACHEPREFIX=/tmp/emoeem-pycache python3 -m py_compile scripts/*.py tests/*.py
            ;;
        *)
            printf 'unknown check: %s\n' "$1" >&2
            return 2
            ;;
    esac
}

usage() {
    printf 'usage: %s [--list] [--only name[,name...]]\n' "$0" >&2
}

main() {
    local -a selected=("${checks[@]}")
    while (( $# > 0 )); do
        case "$1" in
            --list)
                printf '%s\n' "${checks[@]}"
                return 0
                ;;
            --only)
                [[ -n "${2:-}" ]] || { usage; return 2; }
                selected=()
                local rest="$2"
                local name
                # Split on commas with parameter expansion: the list must not
                # depend on an external tool being present, or losing that tool
                # silently selects nothing (see the empty-selection guard).
                while [[ -n "$rest" ]]; do
                    name="${rest%%,*}"
                    [[ -n "$name" ]] && selected+=("$name")
                    if [[ "$rest" == *","* ]]; then
                        rest="${rest#*,}"
                    else
                        rest=""
                    fi
                done
                shift
                ;;
            *)
                usage
                return 2
                ;;
        esac
        shift
    done

    # An empty selection means the argument was wrong (or a helper vanished):
    # reporting "passed (0/N)" here would turn the gate into a silent no-op.
    if (( ${#selected[@]} == 0 )); then
        printf 'no checks selected; nothing to run\n' >&2
        usage
        return 2
    fi

    local unknown=()
    local name
    for name in "${selected[@]}"; do
        local known=0
        local candidate
        for candidate in "${checks[@]}"; do
            [[ "$candidate" == "$name" ]] && known=1
        done
        (( known )) || unknown+=("$name")
    done
    if (( ${#unknown[@]} > 0 )); then
        printf 'unknown check(s): %s\n' "${unknown[*]}" >&2
        printf 'known checks:\n' >&2
        printf '  %s\n' "${checks[@]}" >&2
        return 2
    fi

    local -a failed=()
    for name in "${selected[@]}"; do
        printf '==> %s\n' "$name"
        if ! run_check "$name"; then
            printf 'FAILED %s\n' "$name" >&2
            failed+=("$name")
        fi
    done

    if (( ${#failed[@]} > 0 )); then
        printf 'RESULT static checks failed: %s\n' "${failed[*]}" >&2
        return 1
    fi
    printf 'RESULT static checks passed (%s/%s)\n' "${#selected[@]}" "${#checks[@]}"
}

main "$@"
