#!/usr/bin/env bash
# Single entry point for the whole local verification suite.
#
#   ./tests/run-all.sh            run everything that can run on this host
#   ./tests/run-all.sh --fast     skip the tests that need a container or root
#
# The CI integration job runs the same set, so "it passed locally" and "it
# passed in CI" mean the same thing.
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
readonly root
cd "$root"

fast=0
[[ "${1:-}" == "--fast" ]] && fast=1

# Never write bytecode into the checkout: CI mounts the workspace read-only and
# a stray __pycache__ would also pollute the working tree.
if [[ -z "${PYTHONPYCACHEPREFIX:-}" ]]; then
    PYTHONPYCACHEPREFIX="$(mktemp -d)"
    export PYTHONPYCACHEPREFIX
fi

passed=0
failed=0
skipped=0
declare -a failed_names=()

section() {
    printf '\n== %s ==\n' "$1"
}

report() {
    local rc="$1" name="$2"
    if (( rc == 0 )); then
        passed=$(( passed + 1 ))
        printf 'PASS  %s\n' "$name"
    else
        failed=$(( failed + 1 ))
        failed_names+=("$name")
        printf 'FAIL  %s\n' "$name" >&2
    fi
}

run() {
    local name="$1"
    shift
    "$@" >/dev/null 2>&1
    report $? "$name"
}

section 'Syntax'
for file in manage.sh client/*.sh scripts/*.sh scripts/lib/*.sh tests/*.sh; do
    [[ -f "$file" ]] || continue
    bash -n "$file" >/dev/null 2>&1
    report $? "bash -n $file"
done

section 'Lint'
if command -v shellcheck >/dev/null 2>&1; then
    run 'shellcheck' shellcheck --severity=warning manage.sh client/*.sh scripts/*.sh scripts/lib/*.sh tests/*.sh
else
    skipped=$(( skipped + 1 ))
    printf 'SKIP  shellcheck (not installed)\n'
fi

if command -v actionlint >/dev/null 2>&1; then
    run 'actionlint' actionlint .github/workflows/*.yml
else
    skipped=$(( skipped + 1 ))
    printf 'SKIP  actionlint (not installed)\n'
fi

section 'Python'
python3 -m py_compile scripts/*.py scripts/lib/*.py tests/*.py >/dev/null 2>&1
report $? 'py_compile'

for test_file in tests/test_*.py; do
    [[ -f "$test_file" ]] || continue
    run "$test_file" python3 "$test_file"
done

section 'Behaviour'
for test_file in tests/test-*.sh tests/test_*.sh; do
    [[ -f "$test_file" ]] || continue
    case "$test_file" in
        tests/test-cachyos-environment.sh)
            # Requires the CachyOS builder environment; the builder workflow
            # runs it where that environment exists.
            skipped=$(( skipped + 1 ))
            printf 'SKIP  %s (builder-only)\n' "$test_file"
            continue
            ;;
    esac
    if (( fast == 1 )); then
        case "$test_file" in
            tests/test_repository.sh)
                skipped=$(( skipped + 1 ))
                printf 'SKIP  %s (--fast)\n' "$test_file"
                continue
                ;;
        esac
    fi
    run "$test_file" bash "$test_file"
done

printf '\n----------------------------------------\n'
printf 'passed %d, failed %d, skipped %d\n' "$passed" "$failed" "$skipped"
if (( failed > 0 )); then
    printf 'failures: %s\n' "${failed_names[*]}" >&2
    exit 1
fi
printf 'All local checks passed.\n'
